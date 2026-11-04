# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../scripts/cf_runtime"

class CfRuntimeTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir
    @project = File.join(@home, "project")
    FileUtils.mkdir_p(@project)
    @request = { "version" => 1, "host" => "codex", "project" => @project, "session_id" => "one", "event" => "context" }
  end

  def teardown = FileUtils.remove_entry(@home)

  def call(**values)
    CfRuntime.new(@request.merge(values.transform_keys(&:to_s)), root: File.join(@home, "state"), home: @home).call
  end

  def test_resume_and_project_host_session_isolation
    call(event: "mode.set", mode: "local-only")
    assert_equal "local-only", call.dig("state", "mode")
    assert_equal "merge-ready", call(session_id: "two").dig("state", "mode")
    assert_equal "merge-ready", call(host: "pi").dig("state", "mode")
    other = File.join(@home, "other")
    FileUtils.mkdir_p(other)
    assert_equal "merge-ready", call(project: other).dig("state", "mode")
  end

  def test_child_inherits_but_cannot_overwrite_parent
    call(event: "mode.set", mode: "local-only")
    assert_equal "local-only", call(event: "session.start", session_id: "child", parent_session_id: "one").dig("state", "mode")
    call(event: "mode.set", session_id: "child", mode: "yolo")
    assert_equal "local-only", call.dig("state", "mode")
    assert_equal "yolo", call(session_id: "child").dig("state", "mode")
    assert_raises(ArgumentError) { call(event: "session.start", parent_session_id: "child") }
  end

  def test_four_modes_use_the_same_policy_for_shell_and_structured_actions
    %w[local-only merge-ready admin-bypass yolo].each do |mode|
      call(event: "mode.set", mode: mode)
      shell = call(event: "tool.before", tool: { "name" => "shell", "input" => { "command" => "gh pr merge 4" } })
      structured = call(event: "tool.before", tool: { "name" => "pr.merge", "input" => {} })
      assert_equal shell["decision"], structured["decision"]
      assert_equal %w[local-only merge-ready].include?(mode) ? "deny" : "allow", shell["decision"]
    end
    call(event: "mode.set", mode: "local-only")
    assert_equal "deny", call(event: "tool.before", tool: { "name" => "shell", "input" => { "command" => "gh pr create" } })["decision"]
  end

  def test_invalid_requests_do_not_change_state
    assert_raises(ArgumentError) { call(event: "mode.set", mode: "anything") }
    assert_raises(ArgumentError) { call(session_id: "") }
    assert_raises(ArgumentError) { call(host: "other") }
    assert_equal "merge-ready", call.dig("state", "mode")
  end

  def test_legacy_claude_read_does_not_leak_into_other_hosts
    legacy = File.join(@home, ".claude/cf/sessions/one")
    FileUtils.mkdir_p(legacy)
    File.write(File.join(legacy, "merge-mode"), "local-only")
    assert_equal "local-only", call(host: "claude").dig("state", "mode")
    assert_equal "merge-ready", call.dig("state", "mode")
    call(host: "claude", event: "mode.set", mode: "yolo")
    assert_equal "yolo", call(host: "claude").dig("state", "mode")
    assert_equal "local-only", File.read(File.join(legacy, "merge-mode"))
  end

  def test_parallel_availability_and_mode_writes_preserve_both_fields
    jobs = [ Thread.new { call(event: "mode.set", mode: "local-only") },
             Thread.new { call(event: "availability.set", availability: "away") } ]
    jobs.each(&:value)
    assert_equal({ "mode" => "local-only", "availability" => "away" }, call["state"])
  end
end
