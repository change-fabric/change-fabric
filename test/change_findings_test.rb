# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_findings"

class ChangeFindingsTest < Minitest::Test
  def make_finding(status:, lane: "a11y", check: "check", **rest)
    Finding.new(lane: lane, check: check, status: status, **rest)
  end

  # A Findings holding one pass, one warn, and one failing zap alert.
  def mixed_findings
    findings = Findings.new
    findings.add(make_finding(lane: "a11y", check: "ok", status: "pass"))
    findings.add(make_finding(lane: "a11y", check: "warn", status: "warn"))
    findings.add(make_finding(lane: "zap", check: "bad", status: "fail"))
    findings
  end

  def test_finding_normalizes_unknown_status_to_fail
    finding = make_finding(lane: "k6", check: "x", status: "bogus")
    assert_equal "fail", finding.status
    assert finding.fail?
  end

  def test_header_is_the_row_column_order
    assert_equal %w[lane status severity target check location detail help attempts flaky], Findings::HEADER
  end

  def test_row_serializes_columns_in_header_order
    finding = make_finding(lane: "zap", check: "CSP", status: "warn", severity: "low",
                           target: "http://app", location: "/login", detail: "missing header", help: "url")
    assert_equal [ "zap", "warn", "low", "http://app", "CSP", "/login", "missing header", "url", 1, "false" ],
                 finding.to_row
  end

  # --- attempts and flaky ------------------------------------------------------

  def test_a_finding_records_one_attempt_and_no_flakiness_by_default
    finding = make_finding(status: "pass")
    assert_equal 1, finding.attempts
    refute finding.flaky
  end

  def test_a_nonsense_attempt_count_reads_as_the_single_attempt_that_produced_it
    assert_equal 1, make_finding(status: "pass", attempts: 0).attempts
    assert_equal 1, make_finding(status: "pass", attempts: nil).attempts
  end

  def test_flaky_is_strictly_boolean_and_never_truthy_coerced
    refute make_finding(status: "pass", flaky: "yes").flaky
    assert make_finding(status: "pass", flaky: true).flaky
  end

  def test_with_attempt_copies_the_verdict_and_adds_the_retry_bookkeeping
    original = make_finding(lane: "browserless", check: "desktop", status: "pass", severity: "info",
                            target: "http://app", location: "/", detail: "no responsive break", help: "h")
    retried = original.with_attempt(attempts: 3, flaky: true)

    assert_equal 3, retried.attempts
    assert retried.flaky
    assert_equal original.to_row.first(8), retried.to_row.first(8)
    # The original is never mutated: the lane owns the verdict, the runner only
    # annotates how many attempts reaching it took.
    assert_equal 1, original.attempts
    refute original.flaky
  end

  # A retry never buys a new status. A finding that only passed on the second
  # attempt is a pass carrying flaky: true, not a fourth gate signal.
  def test_statuses_stay_the_three_gate_signals
    assert_equal %w[pass warn fail], Finding::STATUSES
  end

  def test_flaky_findings_are_listed_without_affecting_the_gate
    findings = Findings.new
    findings.add(make_finding(status: "pass").with_attempt(attempts: 2, flaky: true))
    findings.add(make_finding(status: "pass"))

    assert_equal 1, findings.flaky.size
    assert findings.passed?
  end

  def test_passed_when_no_failures
    findings = Findings.new
    findings.add(make_finding(status: "pass"))
    findings.add(make_finding(status: "warn"))
    assert findings.passed?
  end

  def test_lane_status_marks_a_lane_failed_on_any_fail
    findings = mixed_findings
    assert_equal({ "a11y" => "pass", "zap" => "fail" }, findings.lane_status)
    refute findings.passed?
    assert_equal 1, findings.failures.size
  end
end
