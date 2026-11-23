# frozen_string_literal: true

require_relative "pulse_helper"
require "open3"
require "rbconfig"
require_relative "../scripts/pulse_stamp"
require_relative "../scripts/native_hook_install"
require_relative "../scripts/pulse_scope"

# Phase 2 stamps and detects. While Pulse::ACTIVATED is false it must never
# print a dispatch line, arm a watcher or write an engaged cursor.
class PulseStampTest < Minitest::Test
  include PulseHome

  def setup
    super
    @project = File.join(@home, "proj")
    FileUtils.mkdir_p(@project)
    @bin = File.join(@home, "bin")
    FileUtils.mkdir_p(@bin)
    state.update({ "mode" => "merge-ready" })
  end

  def state = CfState.new(host: "claude", project: @project, session_id: @session, root: CfState.root(home: @home), home: @home)

  def stamp(name, at: 0, activated: false, **extra)
    event = { "hook_event_name" => name, "session_id" => @session, "cwd" => @project }.merge(extra.transform_keys(&:to_s))
    PulseStamp.new(event, home: @home, now: t(at), activated: activated, bin: @bin).call
  end

  def install_parts(except: nil)
    (Pulse::READY_PARTS - [ except ].compact).each do |part|
      path = part.end_with?(".md") ? File.join(@home, ".claude", "skills", part.delete_prefix("skills/")) : File.join(@bin, "#{part}.rb")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "")
    end
  end

  def workflow_event(plan = nil) = { tool_name: "Workflow", tool_input: { script: plan ? "#{plan}/workflow.js" : "x" } }

  def make_plan
    plan = File.join(@home, ".claude", "cf", "plans", "area", "slug")
    FileUtils.mkdir_p(plan)
    File.write(File.join(plan, "goal.md"), "Goal.\n")
    plan
  end

  def test_short_session_is_silent_and_detects_nothing
    5.times { |i| assert_nil stamp("PostToolUse", at: i, tool_name: "Bash", tool_input: { command: "ls" }) }
    assert_nil state.pulse["detected_trigger"]
    assert state.pulse["last_activity"]
  end

  def test_workflow_start_records_the_trigger_and_plan_path_without_dispatch
    plan = make_plan
    assert_nil stamp("PostToolUse", **workflow_event(plan))
    assert_equal "workflow", state.pulse.dig("detected_trigger", "trigger")
    assert_equal plan, state.pulse["plan_path"]
    refute state.pulse["engaged_at"]
    refute state.pulse["arm_requested_at"]
    assert_empty PulseStore.new(@session).cursor
  end

  def test_two_open_subagents_trigger_and_stop_closes_them
    stamp("SubagentStart", agent_id: "a1")
    assert_nil state.pulse["detected_trigger"]
    stamp("SubagentStart", at: 1, agent_id: "a2")
    assert_equal "agents", state.pulse.dig("detected_trigger", "trigger")
    stamp("SubagentStop", at: 2, agent_id: "a1")
    assert_equal [ "a2" ], state.pulse["open_subagents"].map { |a| a["id"] }
  end

  def test_away_with_open_work_triggers_but_idle_away_does_not
    state.update({ "availability" => "away" })
    stamp("PostToolUse", tool_name: "Bash", tool_input: {})
    assert_nil state.pulse["detected_trigger"]
    stamp("SubagentStart", at: 1, agent_id: "a1")
    assert_equal "away", state.pulse.dig("detected_trigger", "trigger")
  end

  def test_background_task_counts_as_open_work_for_away
    state.update({ "availability" => "away" })
    stamp("PostToolUse", tool_name: "Bash", tool_input: { "run_in_background" => true })
    assert_equal "away", state.pulse.dig("detected_trigger", "trigger")
  end

  def test_opt_out_stamps_nothing
    state.update_pulse { |pulse| pulse["opted_out"] = true }
    stamp("PostToolUse", **workflow_event)
    assert_nil state.pulse["last_activity"]
  end

  def test_activated_with_every_part_arms_once_then_coalesces
    install_parts
    assert_includes stamp("PostToolUse", activated: true, **workflow_event), "pulse engaged: arm watcher"
    assert state.pulse["engaged_at"]
    assert state.pulse["arm_requested_at"]
    assert_nil stamp("PostToolUse", at: 2, activated: true, tool_name: "Bash", tool_input: {})
    assert_includes stamp("PostToolUse", at: 6, activated: true, tool_name: "Bash", tool_input: {}), "re-arm"
  end

  def test_live_watcher_suppresses_the_arm_request_and_a_dead_pid_brings_it_back
    install_parts
    beat = ->(pid) { File.write(File.join(@dir, "watcher.json"), JSON.generate(heartbeat_at: t(0).iso8601, pid: pid, interval: 60)) }
    beat.call(Process.pid)
    assert_nil stamp("PostToolUse", at: 0, activated: true, **workflow_event)
    beat.call(2**22 + 1)
    assert_includes stamp("PostToolUse", at: 1, activated: true, tool_name: "Bash", tool_input: {}), "arm watcher"
  end

  def test_due_line_follows_the_interval_activity_and_backoff
    install_parts
    File.write(File.join(@dir, "watcher.json"), JSON.generate(heartbeat_at: t(0).iso8601, pid: Process.pid, interval: 99_999))
    stamp("PostToolUse", at: 0, activated: true, **workflow_event)
    assert_nil stamp("PostToolUse", at: 19, activated: true, tool_name: "Bash", tool_input: {})
    assert_equal "[cf] pulse due", stamp("PostToolUse", at: 20, activated: true, tool_name: "Bash", tool_input: {})
    assert_nil stamp("PostToolUse", at: 22, activated: true, tool_name: "Bash", tool_input: {})
    PulseStore.new(@session).advance_cursor("last_pass_at" => t(25).iso8601, "empty_passes" => 1)
    assert_nil stamp("PostToolUse", at: 60, activated: true, tool_name: "Bash", tool_input: {})
    assert_equal "[cf] pulse due", stamp("PostToolUse", at: 66, activated: true, tool_name: "Bash", tool_input: {})
  end

  def test_activated_with_one_part_missing_stays_silent_and_logs_it_once
    install_parts(except: "pulse_integrity")
    2.times { |i| assert_nil stamp("PostToolUse", at: i, activated: true, **workflow_event) }
    log = File.read(File.join(@home, ".claude", "cf", "logs", "pulse.log"))
    assert_equal 1, log.lines.size
    assert_includes log, "pulse_integrity"
    refute state.pulse["engaged_at"]
  end

  def test_a_missing_skill_file_counts_as_a_missing_part
    install_parts(except: "skills/pulse/SKILL.md")
    assert_nil stamp("PostToolUse", activated: true, **workflow_event)
  end

  def test_stop_and_subagent_stop_stamp_but_never_speak
    install_parts
    assert_nil stamp("Stop", activated: true)
    stamp("PostToolUse", activated: true, **workflow_event)
    assert_nil stamp("SubagentStop", at: 400, activated: true, agent_id: "a1")
  end

  def test_unknown_events_bad_session_ids_and_malformed_input_do_not_raise
    assert_nil stamp("SessionStart")
    assert_nil PulseStamp.new({ "hook_event_name" => "Stop", "session_id" => "../x", "cwd" => @project }, home: @home).call
    assert_nil PulseStamp.new({ "hook_event_name" => "Stop", "session_id" => @session, "cwd" => "/no/such" }, home: @home).call
    assert_nil stamp("PostToolUse", tool_name: "Workflow", tool_input: "not a hash")
    assert_nil stamp("PostToolUse", tool_name: 7, tool_input: nil)
  end

  def test_opt_out_cli_sets_and_clears_the_flag_and_refuses_without_a_record
    run = lambda do |*args|
      Open3.capture2e({ "HOME" => @home, "CF_STATE_HOME" => nil }, RbConfig.ruby, File.expand_path("../scripts/pulse_stamp.rb", __dir__), *args)
    end
    out, status = run.call("off", "--session", @session, "--project", @project)
    assert status.success?, out
    assert state.pulse["opted_out"]
    run.call("on", "--session", @session, "--project", @project)
    refute state.pulse["opted_out"]
    _, status = run.call("off", "--session", "unknown", "--project", @project)
    refute status.success?
  end

  def test_dot_dot_is_not_a_session_id
    event = { "hook_event_name" => "Stop", "session_id" => "..", "cwd" => @project }
    assert_nil PulseStamp.new(event, home: @home).call
    refute File.exist?(File.join(@home, ".claude", "cf", "pulse_cursor.json"))
  end

  def test_a_session_with_no_record_is_unknown_not_seeded
    other = CfState.new(host: "claude", project: @project, session_id: "fresh", root: CfState.root(home: @home), home: @home)
    event = { "hook_event_name" => "PostToolUse", "session_id" => "fresh", "cwd" => @project }
    assert_nil PulseStamp.new(event, home: @home).call
    assert_empty other.pulse
    assert_equal({}, other.update_pulse { |pulse| pulse["x"] = 1 })
  end

  def test_pulse_scope_reads_the_recorded_plan_path
    plan = make_plan
    stamp("PostToolUse", **workflow_event(plan))
    sources = PulseScope.new(session: @session, project: @project, home: @home).resolve["sources"]
    assert_equal [ "run_goal" ], sources.map { |s| s["role"] }
  end

  def test_native_hook_install_wires_pulse_for_claude_only_and_unwires_it
    file = File.join(@home, "settings.json")
    foreign = { "hooks" => [ { "type" => "command", "command" => "echo hi" } ] }
    File.write(file, JSON.generate("hooks" => { "SubagentStop" => [ foreign ] }))
    claude = NativeHookInstall.new(path: file, host: "claude", ruby: "/ruby", bin: "/cf bin", backup: false)
    2.times { claude.wire }
    hooks = JSON.parse(File.read(file))["hooks"]
    NativeHookInstall::PULSE_EVENTS.each do |event|
      stamps = hooks.fetch(event).flat_map { |g| g["hooks"] }.select { |h| h["command"].include?("pulse_stamp.rb") }
      assert_equal 1, stamps.size, event
    end
    assert_equal foreign, hooks["SubagentStop"].first
    assert hooks["PostToolUse"].flat_map { |g| g["hooks"] }.any? { |h| h["command"].include?("cf_host_hook.rb") }
    assert_equal 1, hooks["Stop"].size.then { |n| n }, "Stop carries only the pulse stamp for claude"
    claude.unwire
    after = JSON.parse(File.read(file))["hooks"]
    assert_equal [ foreign ], after["SubagentStop"]
    refute_includes File.read(file), "pulse_stamp"

    codex = File.join(@home, "codex.json")
    NativeHookInstall.new(path: codex, host: "codex", ruby: "/ruby", bin: "/cf bin").wire
    refute_includes File.read(codex), "pulse_stamp"
    refute_includes JSON.parse(File.read(codex))["hooks"].keys, "SubagentStop"
  end
end
