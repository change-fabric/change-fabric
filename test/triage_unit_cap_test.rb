# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../scripts/triage/unit_cap"

# C5: 20 launches per host per America/Chicago day, reserved before every
# launch under a file lock and never given back.
class TriageUnitCapTest < Minitest::Test
  NOON = Time.utc(2026, 11, 25, 18, 0, 0)

  def with_root
    Dir.mktmpdir { |root| yield root }
  end

  def cap(root, limit, now = NOON) = Triage::UnitCap.new(root: root, clock: -> { now }, cap: limit)

  def test_the_twenty_first_reservation_of_a_day_is_refused
    with_root do |root|
      store = cap(root, 20)
      20.times { |i| assert store.reserve("a#{i}").granted }
      refused = store.reserve("a20")
      refute refused.granted
      assert_equal 20, refused.used
    end
  end

  def test_reserving_the_same_action_twice_counts_once
    with_root do |root|
      store = cap(root, 2)
      2.times { assert store.reserve("same").granted }
      assert_equal 1, store.used
    end
  end

  def test_concurrent_reservations_never_exceed_the_cap
    with_root do |root|
      granted = 12.times.map { |i| Thread.new { cap(root, 5).reserve("t#{i}").granted } }.map(&:value)
      assert_equal 5, granted.count(true)
      assert_equal 5, cap(root, 5).used
    end
  end

  def test_the_day_rolls_over_at_chicago_midnight
    with_root do |root|
      before = Time.utc(2026, 11, 26, 5, 59, 0) # 23:59 CST on the 25th
      after = Time.utc(2026, 11, 26, 6, 0, 0)   # 00:00 CST on the 26th
      assert cap(root, 1, before).reserve("late").granted
      refute cap(root, 1, before).reserve("late-2").granted
      assert cap(root, 1, after).reserve("next-day").granted
      assert_equal "2026-11-25", Triage::UnitCap.chicago_day(before)
      assert_equal "2026-11-26", Triage::UnitCap.chicago_day(after)
    end
  end

  def test_daylight_time_shifts_the_boundary
    assert_equal "2026-06-30", Triage::UnitCap.chicago_day(Time.utc(2026, 7, 1, 4, 59, 0))
    assert_equal "2026-07-01", Triage::UnitCap.chicago_day(Time.utc(2026, 7, 1, 5, 0, 0))
    assert_equal "2026-03-07", Triage::UnitCap.chicago_day(Time.utc(2026, 3, 8, 5, 59, 0))
    assert_equal "2026-11-01", Triage::UnitCap.chicago_day(Time.utc(2026, 11, 1, 6, 30, 0))
  end

  def test_an_ambiguous_reservation_after_a_restart_stays_counted
    with_root do |root|
      assert cap(root, 2).reserve("crashed-before-dispatch").granted
      restarted = cap(root, 2)
      assert_equal 1, restarted.used
      assert restarted.reserve("next").granted
      refute restarted.reserve("one-too-many").granted
    end
  end

  def test_the_cap_is_configurable_and_survives_a_bad_value
    prior = ENV["CF_TRIAGE_DAILY_CAP"]
    ENV["CF_TRIAGE_DAILY_CAP"] = "3"
    assert_equal 3, Triage::UnitCap.configured
    ENV["CF_TRIAGE_DAILY_CAP"] = "many"
    assert_equal 20, Triage::UnitCap.configured
    ENV.delete("CF_TRIAGE_DAILY_CAP")
    assert_equal 20, Triage::UnitCap.configured
  ensure
    prior ? ENV["CF_TRIAGE_DAILY_CAP"] = prior : ENV.delete("CF_TRIAGE_DAILY_CAP")
  end
end
