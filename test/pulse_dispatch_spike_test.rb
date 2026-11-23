# frozen_string_literal: true

require_relative "pulse_helper"
require_relative "../scripts/pulse_watch"
require_relative "../scripts/pulse_scope"

# C1 scripted half: the watcher exits with a coded event, then the coordinator
# sequence runs a pass with no further parent tool call.
class PulseDispatchSpikeTest < Minitest::Test
  include PulseHome

  def fake_clock
    now = t(0)
    sleeper = ->(seconds) { now += seconds }
    [ -> { now }, sleeper ]
  end

  def stalled_child = write_events({ child_id: "w1", state_digest: "d1", at: t(0).iso8601 })

  def test_watcher_exits_with_stall_code_when_state_is_flat
    stalled_child
    clock, sleeper = fake_clock
    code, event = PulseWatch.new(session: @session, interval: 60, clock: clock, sleeper: sleeper).run
    assert_equal 10, code
    assert_equal "stall", event["event"]
    assert_operator clock.call, :>=, t(30)
  end

  def test_rearmed_watcher_does_not_repeat_an_announced_stall
    stalled_child
    clock, sleeper = fake_clock
    PulseWatch.new(session: @session, clock: clock, sleeper: sleeper).run
    code, event = PulseWatch.new(session: @session, ttl: 600, clock: clock, sleeper: sleeper).run
    assert_equal PulseWatch::TIMEOUT, code
    assert_equal "timeout", event[:event]
  end

  def test_overrun_exit_codes
    File.write(File.join(@dir, "pulse_budgets.json"), JSON.generate([ { command: "suite", budget_s: 600, started_at: t(0).iso8601 } ]))
    clock, sleeper = fake_clock
    assert_equal 11, PulseWatch.new(session: @session, clock: clock, sleeper: sleeper).run.first
  end

  def test_exit_event_drives_a_pass_that_writes_the_ledger_unprompted
    plan = File.join(@home, "plan")
    FileUtils.mkdir_p(plan)
    File.write(File.join(plan, "goal.md"), "Keep the run moving.\n")
    stalled_child
    clock, sleeper = fake_clock
    code, = PulseWatch.new(session: @session, clock: clock, sleeper: sleeper).run
    assert_equal 10, code
    scope = PulseScope.new(session: @session, project: @home, plan_dir: plan).resolve
    due = PulsePrecheck.new(@session, now: clock.call).run
    assert due["due"]
    src = scope["sources"].first
    result = PulseStore.new(@session).append(
      "kind" => "stall", "severity" => "P1", "claim" => "worker w1 stalled", "anchor" => "w1", "evidence" => due["reasons"].join(","),
      "serves" => src.slice("source_path", "revision").merge("quote" => "Keep the run moving", "relevance" => "unstalls")
    )
    assert_equal "stored", result["status"]
    assert_equal 1, File.readlines(File.join(@dir, "pulse.jsonl")).size
  end

  def test_stale_heartbeat_requests_rearm
    clock, = fake_clock
    health = PulseWatch::Health.new(@session, clock: clock, alive: ->(_) { true })
    assert_equal "rearm", health.check
    health.beat(60)
    assert_equal "ok", health.check
    later = PulseWatch::Health.new(@session, clock: -> { t(3) }, alive: ->(_) { true })
    assert_equal "rearm", later.check
  end

  def test_dead_pid_requests_rearm
    clock, = fake_clock
    PulseWatch::Health.new(@session, clock: clock).beat(60)
    assert_equal "rearm", PulseWatch::Health.new(@session, clock: clock, alive: ->(_) { false }).check
  end

  def test_three_failed_starts_emit_pulse_dispatch_down
    health = PulseWatch::Health.new(@session)
    2.times { health.record_failed_start }
    assert_equal "rearm", health.check
    health.record_failed_start
    assert_equal "dispatch_down", health.check
    row = PulseStore.new(@session).rows.last
    assert_equal [ "P0", "pulse-dispatch-down" ], row.values_at("severity", "claim")
    refute_equal "park", row["action_class"]
  end

  def test_cli_failed_start_exit_code
    out = StringIO.new
    2.times { PulseWatch::CLI.run(%w[failed-start --session s1], out: out) }
    assert_equal PulseWatch::DISPATCH_DOWN, PulseWatch::CLI.run(%w[failed-start --session s1], out: out)
  end

  def test_corrupt_heartbeat_file_checks_as_rearm_and_failed_starts_still_count
    File.write(File.join(@dir, "watcher.json"), "{trunc")
    health = PulseWatch::Health.new(@session)
    assert_equal "rearm", health.check
    3.times { health.record_failed_start }
    assert_equal "dispatch_down", health.check
  end

  def test_a_later_outage_records_a_new_p0
    clock = [ t(0) ]
    health = PulseWatch::Health.new(@session, clock: -> { clock.first })
    3.times { health.record_failed_start }
    health.beat(60)
    health.clear_failures
    clock[0] = t(120)
    3.times { health.record_failed_start }
    assert_equal 2, PulseStore.new(@session).rows.count { |r| r["claim"] == "pulse-dispatch-down" }
  end

  def test_a_start_that_fails_its_first_poll_does_not_clear_the_counter
    File.write(File.join(@dir, "pulse_budgets.json"), JSON.generate([ { command: "x", budget_s: 1, started_at: "garbage" } ]))
    health = PulseWatch::Health.new(@session)
    3.times do
      assert_raises(ArgumentError) { PulseWatch.new(session: @session, ttl: 1, sleeper: ->(_) { }).run }
      health.record_failed_start
    end
    assert_equal "dispatch_down", health.check
  end
end
