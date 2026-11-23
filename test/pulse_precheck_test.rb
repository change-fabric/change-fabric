# frozen_string_literal: true

require_relative "pulse_helper"
require_relative "../scripts/pulse_precheck"

# Files and counters stay frozen while --now moves; time alone must wake it.
class PulsePrecheckTest < Minitest::Test
  include PulseHome

  def check(minutes)
    probe = PulsePrecheck.new(@session, now: t(minutes))
    probe.run.tap { |result| probe.commit(result) if result["due"] }
  end

  def frozen_child(extra = [])
    write_events({ child_id: "w1", state_digest: "d1", at: t(0).iso8601 }, *extra)
  end

  def test_nothing_known_is_not_due
    refute check(500)["due"]
  end

  def test_first_sight_then_quiet_then_stall_then_dedup
    frozen_child
    assert_includes check(1)["reasons"], "state_changed"
    refute check(5)["due"]
    assert_includes check(30)["reasons"], "stall:w1"
    refute check(31)["due"]
  end

  def test_interval_due_after_20_minutes_of_frozen_state
    frozen_child([ { child_id: "w1", state_digest: "d1", at: t(0).iso8601, done: true } ])
    check(0)
    refute check(19)["due"]
    assert_equal [ "interval" ], check(20)["reasons"]
    refute check(30)["due"]
  end

  def test_backoff_doubles_up_to_60_minutes
    assert_equal [ 1200, 2400, 3600, 3600 ], [ 0, 1, 2, 5 ].map { |n| PulsePrecheck.interval_s(n) }
  end

  def test_over_budget_at_one_and_a_half_times
    File.write(File.join(@dir, "pulse_budgets.json"), JSON.generate([ { command: "suite", budget_s: 1200, started_at: t(0).iso8601 } ]))
    check(1)
    check(21)
    refute check(29)["due"]
    assert_includes check(30)["reasons"], "over_budget:suite"
    refute check(31)["due"]
  end

  def test_unconsumed_watcher_event_is_due_even_when_state_is_frozen
    frozen_child
    check(1)
    write_events({ child_id: "w1", state_digest: "d1", at: t(0).iso8601 }, { event: "ci_red", at: t(2).iso8601 })
    assert_equal [ "event:ci_red" ], check(2)["reasons"]
    refute check(3)["due"]
  end

  def test_state_change_rearms_a_reported_stall
    frozen_child
    check(1)
    assert check(30)["due"]
    write_events({ child_id: "w1", state_digest: "d1", at: t(0).iso8601 }, { child_id: "w1", state_digest: "d2", at: t(31).iso8601 })
    assert_includes check(31)["reasons"], "state_changed"
    assert_includes check(62)["reasons"], "stall:w1"
  end

  def test_pass_overrun_at_max_seconds
    File.write(File.join(@dir, "pulse_pass.json"), JSON.generate(task_id: "t9", started_at: t(0).iso8601))
    refute check(4)["due"]
    assert_includes check(5)["reasons"], "pass_overrun:t9"
  end

  def test_a_due_result_stays_due_until_committed
    frozen_child
    probe = PulsePrecheck.new(@session, now: t(30))
    assert probe.run["due"]
    assert PulsePrecheck.new(@session, now: t(31)).run["due"]
  end

  def test_stall_after_returning_to_an_earlier_state_is_reported_again
    frozen_child
    check(1)
    assert check(30)["due"]
    write_events({ child_id: "w1", state_digest: "d1", at: t(0).iso8601 }, { child_id: "w1", state_digest: "d2", at: t(31).iso8601 },
                 { child_id: "w1", state_digest: "d1", at: t(32).iso8601 })
    check(32)
    assert_includes check(63)["reasons"], "stall:w1"
  end

  def test_malformed_event_rows_are_skipped
    File.write(File.join(@dir, "pulse_events.jsonl"), "[1]\n{\"child_id\":\"w1\"}\nnot json\n")
    refute check(100)["due"]
  end

  def test_budget_only_session_gets_an_initial_pass
    File.write(File.join(@dir, "pulse_budgets.json"), JSON.generate([ { command: "suite", budget_s: 7200, started_at: t(0).iso8601 } ]))
    assert_includes check(1)["reasons"], "state_changed"
    assert_equal %w[flat_state interval], check(21)["reasons"].sort
  end
end
