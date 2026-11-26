# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require_relative "../scripts/triage/limits"

# C7: classify Claude CLI output into quota_exhausted vs rate_limited, and keep
# the limited-until record that gates dispatch.
class TriageLimitsTest < Minitest::Test
  NOW = Time.utc(2026, 11, 25, 12, 0, 0)

  def frames(*rows) = rows.map { |row| JSON.generate(row) }.join("\n")

  def result(extra = {}) = { "type" => "result", "subtype" => "success", "is_error" => false, "session_id" => "s1", "result" => "done" }.merge(extra)

  def rejected(resets = nil)
    { "type" => "rate_limit_event", "rate_limit_info" => { "status" => "rejected", "rateLimitType" => "seven_day", "resetsAt" => resets }.compact }
  end

  def test_a_normal_result_is_ok_and_keeps_the_session
    outcome = Triage::Limits.classify(frames(result), now: NOW)
    assert_predicate outcome, :ok?
    assert_equal "s1", outcome.session_id
  end

  def test_a_rejected_window_is_quota_exhausted_until_its_reset
    reset = NOW + 86_400 * 3
    outcome = Triage::Limits.classify(frames(rejected(reset.to_i), result("is_error" => true, "result" => "You've hit your weekly limit")), now: NOW)
    assert_equal "quota_exhausted", outcome.klass
    assert_equal reset, outcome.limited_until
  end

  def test_limit_text_without_a_reset_defaults_to_one_hour
    outcome = Triage::Limits.classify(frames(result("is_error" => true, "result" => "You've hit your session limit")), now: NOW)
    assert_equal "quota_exhausted", outcome.klass
    assert_equal NOW + 3600, outcome.limited_until
  end

  def test_out_of_credits_text_is_quota_exhausted
    outcome = Triage::Limits.classify(frames(result("is_error" => true, "result" => "You're out of usage credits")), now: NOW)
    assert_equal "quota_exhausted", outcome.klass
  end

  def test_a_past_reset_falls_back_to_the_default
    outcome = Triage::Limits.classify(frames(rejected((NOW - 60).to_i)), now: NOW)
    assert_equal NOW + 3600, outcome.limited_until
  end

  def test_an_overloaded_error_is_rate_limited_with_a_short_retry
    outcome = Triage::Limits.classify(frames(result("is_error" => true, "result" => "API Error: overloaded_error")), now: NOW)
    assert_equal "rate_limited", outcome.klass
    assert_equal NOW + 900, outcome.limited_until
  end

  def test_exit_zero_with_no_result_frame_is_a_failure
    assert_equal "no_result", Triage::Limits.classify("", now: NOW).klass
    assert_equal "no_result", Triage::Limits.classify(frames({ "type" => "system", "session_id" => "s1" }), now: NOW).klass
  end

  def test_a_budget_stop_is_not_a_quota_signal
    outcome = Triage::Limits.classify(frames(result("subtype" => "error_max_budget_usd", "is_error" => true, "result" => "Reached maximum budget")), now: NOW)
    assert_equal "budget_exhausted", outcome.klass
    refute_predicate outcome, :limit?
  end

  def test_another_error_is_an_error
    assert_equal "error", Triage::Limits.classify(frames(result("is_error" => true, "result" => "boom")), now: NOW).klass
  end

  def test_the_store_gates_until_the_time_passes
    Dir.mktmpdir do |root|
      store = Triage::Limits::Store.new(root: root)
      assert_nil store.active(now: NOW)
      outcome = Triage::Limits::Outcome.new(klass: "quota_exhausted", limited_until: NOW + 7200)
      store.record(outcome, now: NOW)
      assert_equal "quota_exhausted", store.active(now: NOW + 3600)["kind"]
      assert_nil store.active(now: NOW + 7201)
    end
  end

  def test_an_unknown_reset_records_now_plus_one_hour
    Dir.mktmpdir do |root|
      store = Triage::Limits::Store.new(root: root)
      store.record(Triage::Limits::Outcome.new(klass: "quota_exhausted"), now: NOW)
      assert store.active(now: NOW + 3599)
      assert_nil store.active(now: NOW + 3601)
    end
  end

  def test_a_corrupt_record_still_gates
    Dir.mktmpdir do |root|
      File.write(File.join(root, "limits.json"), "{nope")
      assert Triage::Limits::Store.new(root: root).active(now: NOW)
    end
  end
end
