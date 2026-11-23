# frozen_string_literal: true

require_relative "pulse_helper"
require_relative "../scripts/pulse_store"

class PulseBudgetTest < Minitest::Test
  include PulseHome

  def test_parallel_reservers_cannot_exceed_the_cap
    cap = Pulse::DEFAULTS["max_passes_per_day"]
    results = Array.new(cap + 8) { Thread.new { PulseStore.reserve(@home) } }.map(&:value)
    assert_equal cap, results.count { |r| r["reserved"] }
    assert results.last(1).none? { |r| r["reserved"] && r["passes"] > cap }
  end

  def test_exhaustion_is_report_only_and_the_day_rolls_over
    day = Time.utc(2026, 11, 22, 12)
    Pulse::DEFAULTS["max_passes_per_day"].times { PulseStore.reserve(@home, now: day) }
    spent = PulseStore.reserve(@home, now: day)
    assert spent["exhausted"]
    assert_equal "report-only", spent["mode"]
    assert PulseStore.reserve(@home, now: day + 86_400)["reserved"]
  end

  def test_critic_passes_have_their_own_cap
    Pulse::DEFAULTS["max_critic_passes_per_day"].times { assert PulseStore.reserve(@home, critic: true)["reserved"] }
    refute PulseStore.reserve(@home, critic: true)["reserved"]
    assert PulseStore.reserve(@home)["reserved"]
  end

  def test_config_file_overrides_defaults
    File.write(File.join(@home, ".claude", "cf", "pulse.yml"), "pulse:\n  max_passes_per_day: 2\n")
    assert_equal 2, Pulse.config["max_passes_per_day"]
    2.times { PulseStore.reserve(@home) }
    refute PulseStore.reserve(@home)["reserved"]
  end

  def test_corrupt_budget_file_does_not_take_pulse_down
    PulseStore.reserve(@home)
    Dir[File.join(@home, ".claude", "cf", "pulse", "*", "budget.json")].each { |f| File.write(f, "{nope") }
    assert PulseStore.reserve(@home)["reserved"]
  end
end
