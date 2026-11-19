# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "time"
require_relative "../scripts/change_verdict"

# cf.verdict/1 and cf.heartbeat/1: shape, freshness (fail closed), and
# actionability (revision, stage entry, fencing, replay, clock skew).
class ChangeVerdictTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/delivery", __dir__)
  NOW = Time.iso8601("2026-11-18T12:01:30Z")

  def verdict(name = "verdict_pass.json") = JSON.parse(File.read(File.join(FIXTURES, name)))

  def errors(record, **) = ChangeVerdict.verdict_errors(record, **)

  def test_fixtures_are_valid_or_rejected_as_named
    assert_empty errors(verdict)
    assert_empty errors(verdict("verdict_breach.json"))
    assert(errors(verdict("verdict_stale_pass.json")).any? { |e| e.include?("older than 180s") })
    assert_empty ChangeVerdict.heartbeat_errors(verdict("heartbeat.json"))
  end

  def test_shape_errors_name_the_field
    found = errors(verdict.merge("protocol" => "x", "seq" => -1, "verdict" => "great", "stage" => ""))
    %w[protocol seq verdict stage].each { |field| assert(found.any? { |e| e.start_with?(field) }, field) }
    assert_equal [ "verdict must be a JSON object" ], errors([])
    assert(errors(verdict.merge("guards" => [ { "name" => "g", "ok" => "yes", "extra" => 1 } ])).any? { |e| e.include?("guards[0]") })
  end

  def test_pass_is_rejected_on_incomplete_coverage_or_a_failed_guard
    assert(errors(verdict.merge("coverage" => "incomplete")).any? { |e| e.include?("incomplete") })
    guards = verdict["guards"].dup.tap { |g| g[0] = g[0].merge("ok" => false) }
    assert(errors(verdict.merge("guards" => guards)).any? { |e| e.include?("failed guard") })
  end

  def test_unknown_with_stale_telemetry_is_valid
    assert_empty errors(verdict.merge("verdict" => "unknown", "telemetry_at" => "2026-11-18T11:00:00Z"))
  end

  def test_max_age_is_configurable
    assert(errors(verdict.merge("telemetry_at" => "2026-11-18T12:00:50Z"), max_age_s: 5).any?)
  end

  def test_effective_verdict_fails_closed
    assert_equal "pass", ChangeVerdict.effective_verdict(verdict, now: NOW)
    assert_equal "unknown", ChangeVerdict.effective_verdict(verdict, now: NOW + 300)
    assert_equal "unknown", ChangeVerdict.effective_verdict(verdict.merge("coverage" => "incomplete"), now: NOW)
    assert_equal "breach", ChangeVerdict.effective_verdict(verdict("verdict_breach.json"), now: NOW + 3600)
    assert_equal "unknown", ChangeVerdict.effective_verdict(nil, now: NOW)
  end

  def test_heartbeat_gap
    refute ChangeVerdict.heartbeat_gap?("2026-11-18T12:00:00Z", now: NOW)
    assert ChangeVerdict.heartbeat_gap?("2026-11-18T11:50:00Z", now: NOW)
    assert ChangeVerdict.heartbeat_gap?("garbage", now: NOW)
    assert(ChangeVerdict.heartbeat_errors(verdict("heartbeat.json").merge("at" => "later")).any? { |e| e.start_with?("at") })
  end

  def gate(**) = ChangeVerdict::Gate.new(rollout_revision: 3, stage_entry_id: "se-0007", **)

  def test_gate_accepts_then_rejects_a_replay_and_old_seq
    g = gate
    assert_equal [ true, nil ], g.accept(verdict, now: NOW)
    assert_equal [ false, :replayed ], g.accept(verdict, now: NOW)
    assert_equal [ false, :replayed ], g.accept(verdict.merge("seq" => 40), now: NOW)
    assert_equal [ true, nil ], g.accept(verdict.merge("seq" => 42), now: NOW)
  end

  def test_gate_ignores_stale_or_future_revision_in_both_directions
    assert_equal [ false, :stale_revision ], gate.accept(verdict.merge("rollout_revision" => 2), now: NOW)
    assert_equal [ false, :stale_revision ], gate.accept(verdict.merge("rollout_revision" => 4), now: NOW)
  end

  def test_gate_rejects_other_stage_entries_and_low_fencing_tokens
    assert_equal [ false, :wrong_stage_entry ], gate.accept(verdict.merge("stage_entry_id" => "se-0006"), now: NOW)
    assert_equal [ false, :fenced ], gate(fencing_floor: 13).accept(verdict, now: NOW)
  end

  def test_gate_rejects_evaluations_from_the_future_but_allows_small_skew
    assert_equal [ false, :future ], gate.accept(verdict.merge("evaluated_at" => "2026-11-18T12:03:00Z"), now: NOW)
    assert_equal [ true, nil ], gate.accept(verdict.merge("evaluated_at" => "2026-11-18T12:02:20Z"), now: NOW)
  end

  def test_a_new_stage_entry_resets_seq_so_old_passes_are_never_reused
    g = gate
    g.accept(verdict, now: NOW)
    g.enter_stage("se-0008")
    assert_equal [ false, :wrong_stage_entry ], g.accept(verdict, now: NOW)
    assert_equal [ true, nil ], g.accept(verdict.merge("stage_entry_id" => "se-0008", "seq" => 0), now: NOW)
  end
end
