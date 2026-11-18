# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_case_result"

# The case-result record and the history terms derived from it: failing,
# newly failing, flaky, skipped, no history.
class ChangeCaseResultTest < Minitest::Test
  def result(status, run, attempts: 1)
    ChangeCaseResult.new(key: "checkout/pay", suite: "checkout", id: "pay", status: status, run_id: run,
                         attempts: Array.new(attempts) { |n| { "number" => n + 1 } })
  end

  def test_skipped_is_neither_a_failure_nor_a_pass
    skipped = result("skipped", "r1")
    refute skipped.failure?
    refute skipped.pass?
  end

  def test_pass_then_skipped_is_shown_as_skipped_not_newly_failing
    assert_equal :skipped, result("skipped", "r2").trend([ result("pass", "r1") ])
  end

  # The run where the case was not selected has no record at all, so the
  # comparison reaches back to the pass.
  def test_pass_then_unselected_then_fail_is_newly_failing
    history = [ result("pass", "r1") ]
    assert_equal :newly_failing, result("fail", "r3").trend(history)
  end

  def test_pass_then_skipped_then_fail_compares_against_the_pass
    history = [ result("pass", "r1"), result("skipped", "r2") ]
    assert_equal :newly_failing, result("auth_interrupted", "r3").trend(history)
  end

  def test_no_history_then_fail_is_failing_with_no_history
    current = result("fail", "r1")
    assert current.failure?
    assert_equal :no_history, current.trend([])
  end

  def test_fail_then_fail_is_failing_not_newly_failing
    assert_equal :failing, result("partial_evidence", "r2").trend([ result("fail", "r1") ])
  end

  def test_a_pass_after_a_failed_attempt_is_flaky
    assert_equal :flaky, result("pass", "r1", attempts: 2).trend([])
    assert_equal :pass, result("pass", "r1").trend([])
  end

  def test_round_trips_through_a_hash
    original = result("fail", "r1")
    assert_equal original.to_h, ChangeCaseResult.from_h(JSON.parse(original.to_json)).to_h
  end

  def test_an_unknown_status_is_refused
    assert_raises(ArgumentError) { result("passed", "r1") }
  end
end
