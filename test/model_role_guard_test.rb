# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "stringio"
require "open3"
require_relative "../scripts/model_role_guard"

class ModelRoleGuardTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @snapshot = File.join(@dir, "snap.json")
    ModelRoles.write_snapshot(host: "claude", roles: { "worker" => "sonnet", "critic" => "opus" },
                              sources: {}, path: @snapshot)
  end

  def teardown = FileUtils.rm_rf(@dir)

  def spawn_event(input = {}, tool: "Agent", **loose) = { "tool_name" => tool, "tool_input" => input.merge(loose) }

  def run_guard(event, env: {}, snapshot: @snapshot)
    io = StringIO.new
    ModelRoleGuard.new(event, snapshot_path: snapshot, env: env).emit(io)
    io.string.empty? ? nil : JSON.parse(io.string).dig("hookSpecificOutput", "additionalContext")
  end

  def test_tagged_mismatch_warns_naming_role_expected_and_actual
    text = run_guard(spawn_event("description" => "[role:worker] scan files", "model" => "opus"))
    assert_includes text, "[role:worker]"
    assert_includes text, "sonnet"
    assert_includes text, "model opus"
  end

  def test_tagged_spawn_with_no_model_warns
    assert_includes run_guard(spawn_event("description" => "[role:critic] judge")), "no model"
  end

  def test_tag_as_first_token_of_prompt_counts
    assert run_guard(spawn_event("description" => "scan", "prompt" => "[role:worker] go", "model" => "opus"))
  end

  def test_legacy_task_tool_is_guarded
    assert run_guard(spawn_event({ "description" => "[role:worker] x", "model" => "opus" }, tool: "Task"))
  end

  def test_tagged_match_is_silent
    assert_nil run_guard(spawn_event("description" => "[role:worker] scan", "model" => "sonnet"))
  end

  def test_untagged_is_silent
    assert_nil run_guard(spawn_event("description" => "scan", "model" => "opus"))
  end

  def test_unknown_role_is_silent
    assert_nil run_guard(spawn_event("description" => "[role:janitor] scan", "model" => "opus"))
  end

  def test_non_agent_tool_is_silent
    assert_nil run_guard({ "tool_name" => "Bash", "tool_input" => { "description" => "[role:worker] x", "model" => "opus" } })
  end

  def test_missing_snapshot_is_silent
    assert_nil run_guard(spawn_event("description" => "[role:worker] x", "model" => "opus"), snapshot: File.join(@dir, "none.json"))
  end

  def test_kill_switch_silences
    assert_nil run_guard(spawn_event("description" => "[role:worker] x", "model" => "opus"), env: { "CF_MODEL_ROLE_GUARD" => "0" })
  end

  def test_malformed_payloads_are_silent
    assert_nil run_guard({})
    assert_nil run_guard({ "tool_name" => "Agent", "tool_input" => "text" })
    assert_nil run_guard(spawn_event("description" => 7, "model" => nil))
  end

  def test_script_exits_zero_on_garbage_and_on_a_warning
    script = File.expand_path("../scripts/model_role_guard.rb", __dir__)
    _, status = Open3.capture2e("ruby", script, stdin_data: "not json")
    assert status.success?
    out, status = Open3.capture2e({ "HOME" => @dir, "CF_STATE_HOME" => @dir }, "ruby", script,
                                  stdin_data: JSON.generate(spawn_event("description" => "[role:worker] x", "model" => "opus")))
    assert status.success?
    assert_equal "", out # no snapshot in this state dir
  end
end
