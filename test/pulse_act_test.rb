# frozen_string_literal: true

require_relative "pulse_helper"
require "open3"
require "rbconfig"
require_relative "../scripts/pulse_act"
require_relative "../scripts/cf_state"

# C3 through the same sequence the live coordinator runs: authorize, begin, a
# stub tool, ack. The act service never touches a worker itself.
class PulseActTest < Minitest::Test
  include PulseHome

  def setup
    super
    @project = File.join(@home, "proj")
    @plan = File.join(@home, "plan")
    FileUtils.mkdir_p([ @project, @plan ])
    write_plan("Land phase one.\n", "# Plan\npulse-allow: nudge_worker, stop_runaway\n")
    set_mode("admin-bypass")
    write_events({ child_id: "w1", state_digest: "d1", at: t(0).iso8601 })
    @finding = PulseStore.new(@session).append(finding)["id"]
  end

  def set_mode(mode) = CfState.new(host: "claude", project: @project, session_id: @session).update({ "mode" => mode })

  def write_plan(goal, plan)
    File.write(File.join(@plan, "goal.md"), goal)
    File.write(File.join(@plan, "plan.md"), plan)
    sources = { "run_goal" => "goal.md", "run_plan" => "plan.md" }.map do |role, name|
      { "role" => role, "source_path" => File.join(@plan, name), "revision" => Pulse.sha(File.read(File.join(@plan, name))) }
    end
    File.write(File.join(@dir, "pulse_scope.json"), JSON.generate("sources" => sources))
  end

  def finding(extra = {})
    goal = JSON.parse(File.read(File.join(@dir, "pulse_scope.json")))["sources"].first
    { "kind" => "stall", "severity" => "P2", "claim" => "w1 stalled", "evidence" => "no state change", "anchor" => "w1 stall",
      "action_class" => "auto",
      "serves" => { "source_path" => goal["source_path"], "revision" => goal["revision"], "quote" => "Land phase one", "relevance" => "keeps it moving" } }.merge(extra)
  end

  def act(minutes = 5, **opts) = PulseAct.new(@session, project: @project, now: t(minutes), **opts)

  def authorize(action = "nudge_worker", target = "w1", observed: t(0).iso8601, minutes: 5)
    act(minutes).authorize(finding: @finding, action: action, target: target, observed_at: observed, text: "please report status")
  end

  def test_authorized_nudge_runs_once_through_the_adapter_sequence
    auth = authorize
    assert_equal "authorized", auth["state"]
    assert_equal({ "tool" => "SendMessage", "args" => { "target_id" => "w1", "text" => "please report status" } }, auth["command"])
    assert_equal t(10).utc.iso8601, auth["expires_at"]
    assert_equal "executing", act.begin(auth["key"])["state"]
    assert_equal "acked", act.ack(auth["key"], result: "ok")["state"]
    again = authorize
    assert_equal [ "acked", true ], again.values_at("state", "idempotent")
    assert_nil again["command"]
  end

  def test_repeat_authorize_returns_the_same_key_and_a_second_begin_is_refused
    first = authorize
    assert_equal first["key"], authorize["key"]
    assert_equal "executing", act.begin(first["key"])["state"]
    assert_equal "not-authorized:executing", act.begin(first["key"])["reason"]
    assert_equal "in-flight", authorize["reason"]
  end

  def test_each_action_maps_to_one_tool
    write_plan("Land phase one.\n", "pulse-allow: stop_runaway, reorder_phase\n")
    assert_equal({ "tool" => "TaskStop", "args" => { "target_id" => "w1" } }, authorize("stop_runaway")["command"])
    assert_equal "Workflow", authorize("reorder_phase")["command"]["tool"]
  end

  def test_denials_queue_a_proposal
    set_mode("local-only")
    assert_equal "local-only", authorize["reason"]
    set_mode("yolo")
    assert_equal "action-not-allowed", authorize("kill_everything")["reason"]
    assert_equal "stale-target", authorize("nudge_worker", "w1", observed: t(-5).iso8601)["reason"]
    assert_equal "stale-target", authorize("nudge_worker", "other-session-worker")["reason"]
    assert_equal 4, act.proposals.size
    assert_equal "local-only", act.proposals.first["reason"]
  end

  def test_out_of_protocol_and_out_of_scope_are_denied
    write_plan("A different goal.\n", "pulse-allow: nudge_worker\n")
    assert_equal "out-of-scope", authorize["reason"], "the cited quote is gone from the current goal"
    write_plan("Land phase one.\n", "no allow line\n")
    id = PulseStore.new(@session).append(finding("anchor" => "second"))["id"]
    denied = act.authorize(finding: id, action: "nudge_worker", target: "w1", observed_at: t(0).iso8601, text: "hi")
    assert_equal "not-in-protocol", denied["reason"]
  end

  def test_a_finding_that_is_not_auto_or_not_authorizable_is_denied
    report = PulseStore.new(@session).append(finding("anchor" => "r", "action_class" => "report"))["id"]
    assert_equal "not-authorizable", act.authorize(finding: report, action: "nudge_worker", target: "w1", observed_at: t(0).iso8601, text: "x")["reason"]
    assert_equal "unknown-finding", act.authorize(finding: "nope", action: "nudge_worker", target: "w1", observed_at: t(0).iso8601, text: "x")["reason"]
  end

  def test_hard_limit_text_is_denied
    [ "CF_ALLOW_UNGATED_MERGE=1 now", "run git tag v1", "deploy to prod" ].each do |text|
      denied = act.authorize(finding: @finding, action: "nudge_worker", target: "w1", observed_at: t(0).iso8601, text: text)
      assert_equal "hard-limit", denied["reason"], text
    end
  end

  def test_begin_rechecks_freshness_expiry_and_mode
    key = authorize["key"]
    write_events({ child_id: "w1", state_digest: "d2", at: t(6).iso8601 })
    assert_equal "stale-target", act(7).begin(key)["reason"]
    key = authorize(minutes: 7, observed: t(6).iso8601)["key"]
    assert_equal "expired", act(13).begin(key)["reason"]
    key = authorize(minutes: 13, observed: t(6).iso8601)["key"]
    set_mode("local-only")
    assert_equal "local-only", act(14).begin(key)["reason"]
    assert_equal "not-authorized:denied", act.begin(key)["reason"]
  end

  def test_a_key_left_executing_is_reconciled_before_any_retry
    key = authorize("stop_runaway")["key"]
    act.begin(key)
    assert_equal "failed", act(6).reconcile(key)["state"], "task still running: effect not visible"
    assert_equal "authorized", authorize("stop_runaway", minutes: 7)["state"], "a failed key needs a new authorization"
    act(7).begin(key)
    write_events({ child_id: "w1", state_digest: "d1", at: t(0).iso8601 }, { child_id: "w1", state_digest: "d1", at: t(0).iso8601, done: true })
    assert_equal "acked", act(8).reconcile(key)["state"]
  end

  def test_an_interrupted_nudge_is_acked_only_when_visible_in_the_transcript
    key = authorize["key"]
    act.begin(key)
    transcript = File.join(@home, "transcript.txt")
    File.write(transcript, "assistant: sent please report status\n")
    assert_equal "acked", act.reconcile(key, transcript: transcript)["state"]
    assert_equal "not-executing", act.reconcile(key, transcript: transcript)["reason"]
  end

  def test_ack_requires_an_executing_key_and_records_an_error
    key = authorize["key"]
    assert_equal "not-executing", act.ack(key, result: "ok")["reason"]
    act.begin(key)
    assert_equal "failed", act.ack(key, result: "error", detail: "tool refused")["state"]
  end

  def test_notify_delivers_once_and_retries_a_failure_once
    PulseStore.new(@session).append_system("kind" => "integrity", "severity" => "P0", "claim" => "vacuous pass", "evidence" => "rows 0", "anchor" => "r")
    id = PulseStore.new(@session).rows.last["id"]
    PulseStore.new(@session).queue_notify(id)
    calls = []
    inbox = ->(subject, _body, ref) { calls << [ subject, ref ]; { ok: calls.size > 2 } }
    assert_equal [ "failed" ], act(inbox: inbox).notify.map { |r| r["state"] }
    assert_equal [ "failed" ], act(inbox: inbox).notify.map { |r| r["state"] }
    assert_empty act(inbox: inbox).notify, "two attempts are the cap"
    assert_equal [ [ "pulse P0: vacuous pass", id ] ] * 2, calls
  end

  def test_notify_writes_a_real_inbox_item
    ENV["INBOX_ROOT"] = File.join(@home, "inbox")
    _, status = Open3.capture2(RbConfig.ruby, File.expand_path("../scripts/inbox_store.rb", __dir__), "init", "--roles", "A,B")
    assert status.success?
    PulseStore.new(@session).append_system("kind" => "integrity", "severity" => "P0", "claim" => "vacuous pass", "evidence" => "rows 0", "anchor" => "r")
    id = PulseStore.new(@session).rows.last["id"]
    PulseStore.new(@session).queue_notify(id)
    assert_equal [ "delivered" ], act.notify.map { |r| r["state"] }
    assert_equal 2, Dir.glob(File.join(@home, "inbox", "inbox", "*", "*pulse-p0*")).size
  ensure
    ENV.delete("INBOX_ROOT")
  end

  def test_unknown_target_or_blank_observed_at_is_stale_never_authorized
    %w[ghost w1].each do |target|
      denied = act.authorize(finding: @finding, action: "nudge_worker", target: target, observed_at: "", text: "hi")
      assert_equal "stale-target", denied["reason"], target
    end
    assert_equal "stale-target", act.authorize(finding: @finding, action: "nudge_worker", target: "", observed_at: "", text: "hi")["reason"]
  end

  def test_the_pulse_pass_and_budget_commands_are_not_nudge_or_pass_targets
    File.write(File.join(@dir, "pulse_pass.json"), JSON.generate(task_id: "pulse-pass", started_at: t(0).iso8601))
    File.write(File.join(@dir, "pulse_budgets.json"), JSON.generate([ { command: "suite", budget_s: 60, started_at: t(0).iso8601 } ]))
    assert_equal "stale-target", authorize("stop_runaway", "pulse-pass")["reason"]
    assert_equal "stale-target", authorize("nudge_worker", "suite")["reason"]
    assert_equal "authorized", authorize("stop_runaway", "suite")["state"]
  end

  def test_a_cached_authorization_is_rechecked_and_follows_the_text
    first = authorize
    set_mode("local-only")
    assert_equal "local-only", authorize["reason"]
    set_mode("yolo")
    other = act.authorize(finding: @finding, action: "nudge_worker", target: "w1", observed_at: t(0).iso8601, text: "different")
    assert_equal "different", other["command"]["args"]["text"]
    assert_equal first["key"], other["key"]
  end

  def test_a_key_that_failed_twice_needs_a_new_finding
    2.times do |i|
      key = authorize(minutes: 5 + i)["key"]
      act(5 + i).begin(key)
      act(5 + i).ack(key, result: "error")
    end
    assert_equal "attempts-exhausted", authorize(minutes: 8)["reason"]
  end

  def test_cli_round_trip
    out = StringIO.new
    code = PulseActCLI.run(%W[authorize --session #{@session} --project #{@project} --finding #{@finding} --action nudge_worker --target w1
                              --observed-at #{t(0).iso8601} --text hello --now #{t(5).iso8601}], out: out)
    assert_equal 0, code
    assert_equal "authorized", JSON.parse(out.string)["state"]
    assert_equal 2, PulseActCLI.run(%w[begin --session s1], out: StringIO.new)
  end
end
