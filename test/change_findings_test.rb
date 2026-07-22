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
    assert_equal %w[lane status severity target check location detail help], Findings::HEADER
  end

  def test_row_serializes_columns_in_header_order
    finding = make_finding(lane: "zap", check: "CSP", status: "warn", severity: "low",
                           target: "http://app", location: "/login", detail: "missing header", help: "url")
    assert_equal [ "zap", "warn", "low", "http://app", "CSP", "/login", "missing header", "url" ], finding.to_row
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
