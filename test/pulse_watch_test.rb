# frozen_string_literal: true

require_relative "pulse_helper"
require_relative "../scripts/pulse_watch"

# The watcher on a fake clock: fixture state dirs, no real sleeping.
class PulseWatchTest < Minitest::Test
  include PulseHome

  def watcher(start = 0, ttl: 3 * 3600, interval: 60, prs: nil)
    @now = t(start)
    PulseWatch.new(session: @session, interval: interval, ttl: ttl, clock: -> { @now }, sleeper: ->(s) { @now += s }, prs: prs)
  end

  def run_watch(**opts) = watcher(opts.delete(:start) || 0, **opts).run

  def test_each_pushed_event_exits_with_the_events_code
    PulseWatch::EVENTS.each do |name|
      FileUtils.rm_f(File.join(@dir, "pulse_events.jsonl"))
      FileUtils.rm_f(File.join(@dir, "watcher.json"))
      PulseWatch.push(@session, name, {}, clock: -> { t(0) })
      code, event = run_watch(ttl: 10)
      assert_equal [ PulseWatch::CODES["events"], [ name ] ], [ code, event[:names] || event["names"] ], name
    end
  end

  def test_a_burst_is_coalesced_to_one_exit_five_minutes_after_the_last
    PulseWatch.push(@session, "gate_verdict", {}, clock: -> { t(0) })
    first = run_watch(ttl: 10)
    assert_equal 16, first.first
    PulseWatch.push(@session, "ci_red", {}, clock: -> { t(1) })
    PulseWatch.push(@session, "retry_started", {}, clock: -> { t(2) })
    code, event = watcher(1, ttl: 20 * 60).run
    assert_equal 16, code
    assert_equal %w[ci_red retry_started], event["names"]
    assert_operator @now, :>=, t(5), "held for the 5 minute coalesce gap"
    assert_equal PulseWatch::TIMEOUT, watcher(6, ttl: 600).run.first, "already announced"
  end

  def test_a_deadline_exit_does_not_swallow_a_pending_event
    PulseWatch.push(@session, "pr_merged", {}, clock: -> { t(0) })
    write_events(*File.readlines(File.join(@dir, "pulse_events.jsonl")).map { |l| JSON.parse(l) }, { child_id: "w1", state_digest: "d", at: t(0).iso8601 })
    assert_equal 10, run_watch(start: 31, ttl: 10).first, "the stall exits first"
    code, event = run_watch(start: 32, ttl: 10)
    assert_equal [ 16, [ "pr_merged" ] ], [ code, event["names"] ]
  end

  def test_a_session_id_cannot_leave_the_cf_tree
    [ "../../x", "a/b", "..", "" ].each { |bad| assert_raises(ArgumentError, bad) { Pulse.session_dir(bad) } }
    assert_equal PulseWatch::SETUP, PulseWatch::CLI.run(%w[emit --session ../../x --event ci_red], out: StringIO.new)
  end

  def test_unknown_events_are_rejected
    assert_raises(ArgumentError) { PulseWatch.push(@session, "made_up") }
  end

  def test_stall_and_over_budget_exit_at_once_without_coalescing
    write_events({ child_id: "w1", state_digest: "d", at: t(0).iso8601 })
    File.write(File.join(@dir, "pulse_budgets.json"), JSON.generate([ { command: "suite", budget_s: 600, started_at: t(0).iso8601 } ]))
    codes = []
    codes << run_watch(start: 15, ttl: 3600).first until codes.size == 2
    assert_equal [ 10, 11 ], codes.sort
  end

  def test_pass_overrun_exits_at_the_wall_clock
    File.write(File.join(@dir, "pulse_pass.json"), JSON.generate(task_id: "pulse-1", started_at: t(0).iso8601))
    code, event = run_watch(start: 5, ttl: 3600)
    assert_equal [ 12, "pulse-1" ], [ code, event["task_id"] ]
    assert_operator @now, :>=, t(5)
  end

  def test_flat_state_with_a_running_command_fires_after_one_interval_and_not_once_finished
    File.write(File.join(@dir, "pulse_budgets.json"), JSON.generate([ { command: "suite", budget_s: 99_999, started_at: t(0).iso8601 } ]))
    assert_equal 14, run_watch(start: 21, ttl: 60).first
    File.write(File.join(@dir, "pulse_budgets.json"), JSON.generate([ { command: "suite", budget_s: 99_999, started_at: t(0).iso8601, finished_at: t(22).iso8601 } ]))
    FileUtils.rm_f(File.join(@dir, "watcher.json"))
    assert_equal PulseWatch::TIMEOUT, run_watch(start: 60, ttl: 60).first
  end

  def test_backoff_follows_the_store_empty_pass_count
    write_events({ child_id: "w1", state_digest: "d", at: t(0).iso8601, done: true })
    PulseStore.new(@session).advance_cursor("engaged_at" => t(0).iso8601, "empty_passes" => 0)
    write_events({ child_id: "w1", state_digest: "d", at: t(0).iso8601 })
    assert PulsePrecheck.new(@session, now: t(20)).interval_deadline
    PulseStore.new(@session).advance_cursor("empty_passes" => 2)
    assert_nil PulsePrecheck.new(@session, now: t(40)).interval_deadline
    assert PulsePrecheck.new(@session, now: t(60)).interval_deadline
  end

  def test_the_interval_deadline_exits_once_per_pass
    write_events({ child_id: "w1", state_digest: "d", at: t(0).iso8601, done: true })
    PulseStore.new(@session).advance_cursor("engaged_at" => t(0).iso8601)
    assert_equal 15, run_watch(start: 20, ttl: 60).first
    assert_equal PulseWatch::TIMEOUT, run_watch(start: 21, ttl: 60).first
  end

  def test_pr_poll_emits_opened_merged_and_ci_red_after_a_baseline
    snapshots = [
      [ { "number" => 1, "state" => "OPEN", "head_sha" => "a", "ci_red" => false } ],
      [ { "number" => 1, "state" => "OPEN", "head_sha" => "a", "ci_red" => true }, { "number" => 2, "state" => "OPEN", "head_sha" => "b", "ci_red" => false } ],
      [ { "number" => 1, "state" => "MERGED", "head_sha" => "a", "ci_red" => true }, { "number" => 2, "state" => "OPEN", "head_sha" => "b", "ci_red" => false } ]
    ]
    prs = -> { snapshots.size > 1 ? snapshots.shift : snapshots.first }
    watch = watcher(0, prs: prs)
    watch.send(:poll_prs)
    refute File.exist?(File.join(@dir, "pulse_events.jsonl")), "the first poll is a baseline"
    2.times { watch.send(:poll_prs) }
    names = File.readlines(File.join(@dir, "pulse_events.jsonl")).map { |l| JSON.parse(l)["event"] }
    assert_equal %w[ci_red pr_opened pr_merged], names
  end

  def test_cli_emit_and_unknown_event_setup_error
    out = StringIO.new
    assert_equal 0, PulseWatch::CLI.run(%w[emit --session s1 --event pr_parked --pr 7], out: out)
    assert_equal 7, JSON.parse(out.string)["pr"]
    assert_equal PulseWatch::SETUP, PulseWatch::CLI.run(%w[emit --session s1 --event nope], out: StringIO.new)
  end
end
