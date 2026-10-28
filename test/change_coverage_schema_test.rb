# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_coverage_schema"

class ChangeCoverageSchemaTest < Minitest::Test
  def item(id, status, flaky: false) = { "id" => id, "status" => status, "flaky" => flaky }

  def test_cap_cases_keeps_a_failure_that_sits_past_the_cap
    items = Array.new(6000) { |index| item("pass-#{index}", "pass") }
    items << item("late-failure", "fail")

    kept, truncated = ChangeCoverageSchema.cap_cases(items, 500)

    assert truncated
    assert_equal 500, kept.size
    assert_equal "late-failure", kept.first["id"]
  end

  def test_cap_cases_ranks_by_keep_order_and_keeps_input_order_within_a_status
    items = [
      item("p1", "pass"), item("s1", "skip"), item("f1", "pass", flaky: true), item("e1", "error"),
      item("x1", "fail"), item("w1", "warn"), item("x2", "fail"), item("p2", "pass")
    ]

    kept, truncated = ChangeCoverageSchema.cap_cases(items, 10)

    refute truncated
    assert_equal %w[x1 x2 e1 f1 w1 s1 p1 p2], kept.map { |entry| entry["id"] }
  end

  def test_a_flaky_failure_still_ranks_as_a_failure
    kept, = ChangeCoverageSchema.cap_cases([ item("flaky-pass", "pass", flaky: true), item("flaky-fail", "fail", flaky: true) ], 1)

    assert_equal [ "flaky-fail" ], kept.map { |entry| entry["id"] }
  end

  def test_not_scanned_is_a_route_cell_status
    assert_includes ChangeCoverageSchema::ROUTE_CELL_STATUSES, "not_scanned"
  end
end
