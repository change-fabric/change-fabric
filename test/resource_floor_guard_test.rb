# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "stringio"
require "open3"
require_relative "../scripts/resource_floor_guard"

class ResourceFloorGuardTest < Minitest::Test
  RG = ResourceGate

  # A gate double: returns a canned Result and records what it was asked.
  class FakeGate
    attr_reader :calls

    def initialize(result = nil, error: nil)
      @result = result
      @error = error
      @calls = []
    end

    def check(**kwargs)
      @calls << kwargs
      raise @error if @error

      @result
    end
  end

  def below_floor
    json = { ok: false, error: nil, notes: [], ram_available_mb: 900, disk_free_gb: 4.5,
             need: { ram_mb: 2048, disk_gb: 10, source: "default" }, candidates: [], provisional: true }
    RG::Result.new(json: json, exit_code: 3)
  end

  def fine = RG::Result.new(json: { ok: true }, exit_code: 0)
  def measurement_error = RG::Result.new(json: { ok: false, error: "measurement" }, exit_code: 4)

  def spawn_event(tool: "Agent") = { "tool_name" => tool, "tool_input" => { "description" => "x" } }

  def run_guard(event, gate:, env: {}, worktrees: 1)
    io = StringIO.new
    ResourceFloorGuard.new(event, gate: gate, worktrees: worktrees, env: env).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string)
  end

  def test_below_floor_warns_with_readings_and_never_denies
    out = run_guard(spawn_event, gate: FakeGate.new(below_floor))
    text = out.dig("hookSpecificOutput", "additionalContext")
    assert_equal "PreToolUse", out.dig("hookSpecificOutput", "hookEventName")
    assert_includes text, "900 MB RAM"
    assert_includes text, "4.5 GB disk"
    assert_includes text, "CF_RESOURCE_GUARD=0"
    refute out["hookSpecificOutput"].key?("permissionDecision")
    refute out.key?("decision")
  end

  def test_task_tool_is_covered_too
    assert run_guard(spawn_event(tool: "Task"), gate: FakeGate.new(below_floor))
  end

  def test_silent_when_at_or_above_floor
    assert_nil run_guard(spawn_event, gate: FakeGate.new(fine))
  end

  def test_silent_on_measurement_error_unlike_the_gate
    assert_nil run_guard(spawn_event, gate: FakeGate.new(measurement_error))
  end

  def test_silent_when_the_gate_raises
    assert_nil run_guard(spawn_event, gate: FakeGate.new(error: RuntimeError.new("boom")))
  end

  def test_other_tools_never_reach_the_gate
    gate = FakeGate.new(below_floor)
    assert_nil run_guard({ "tool_name" => "Bash", "tool_input" => {} }, gate: gate)
    assert_nil run_guard({}, gate: gate)
    assert_empty gate.calls
  end

  def test_env_switch_disables_it_without_reading
    gate = FakeGate.new(below_floor)
    assert_nil run_guard(spawn_event, gate: gate, env: { "CF_RESOURCE_GUARD" => "0" })
    assert_empty gate.calls
  end

  def test_never_reclaims_and_passes_the_live_worktree_count
    gate = FakeGate.new(below_floor)
    run_guard(spawn_event, gate: gate, worktrees: 4)
    assert_equal [ { worktrees: 4, reclaim_safe: false } ], gate.calls
  end

  def test_live_worktrees_counts_the_repo_checkouts_from_git
    Dir.mktmpdir do |dir|
      repo = File.join(dir, "r")
      Dir.mkdir(repo)
      system("git", "-C", repo, "init", "-q", exception: true)
      system("git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@e.x", "commit", "-q", "--allow-empty", "-m", "i", exception: true)
      system("git", "-C", repo, "worktree", "add", "-q", File.join(dir, "w1"), "-b", "w1", exception: true)
      gate = FakeGate.new(fine)
      ResourceFloorGuard.new({ "tool_name" => "Agent", "cwd" => repo }, gate: gate, env: {}).warning
      assert_equal 2, gate.calls.first[:worktrees]
    end
  end

  def test_script_exits_zero_with_no_output_on_garbage_and_when_disabled
    script = File.expand_path("../scripts/resource_floor_guard.rb", __dir__)
    out, status = Open3.capture2e("ruby", script, stdin_data: "not json")
    assert status.success?
    assert_equal "", out
    out, status = Open3.capture2e({ "CF_RESOURCE_GUARD" => "0" }, "ruby", script, stdin_data: JSON.generate(spawn_event))
    assert status.success?
    assert_equal "", out
  end

  def test_script_warns_end_to_end_when_the_floor_is_raised_above_the_machine
    script = File.expand_path("../scripts/resource_floor_guard.rb", __dir__)
    env = { "CF_FLOOR_RAM_MB" => "99999999" }
    out, status = Open3.capture2e(env, "ruby", script, stdin_data: JSON.generate(spawn_event.merge("cwd" => Dir.pwd)))
    assert status.success?
    assert_includes JSON.parse(out).dig("hookSpecificOutput", "additionalContext"), "resource floor"
  end
end
