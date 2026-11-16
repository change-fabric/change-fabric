# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/plan_phase_trailer"

class PlanPhaseTrailerTest < Minitest::Test
  REF = "demo-area/widget-plan#Phase 2"

  def test_parse_returns_first_trailer_value
    body = "Adds the widget.\n\nPlan-Phase: #{REF}\nPlan-Phase: demo-area/widget-plan#Phase 3\n"
    assert_equal REF, PlanPhaseTrailer.parse(body)
  end

  def test_parse_tolerates_crlf_and_indent
    assert_equal REF, PlanPhaseTrailer.parse("Summary\r\n  Plan-Phase: #{REF}\r\n")
  end

  def test_parse_returns_nil_without_a_well_formed_trailer
    assert_nil PlanPhaseTrailer.parse(nil)
    assert_nil PlanPhaseTrailer.parse("no trailer here")
    assert_nil PlanPhaseTrailer.parse("Plan-Phase: widget-plan#Phase 2")
    assert_nil PlanPhaseTrailer.parse("See Plan-Phase: #{REF} inline")
    assert_nil PlanPhaseTrailer.parse("Plan-Phase: #{REF} trailing words")
  end

  def test_parse_skips_malformed_lines_for_a_later_good_one
    assert_equal REF, PlanPhaseTrailer.parse("Plan-Phase: oops\nPlan-Phase: #{REF}")
  end

  def test_line_renders_and_round_trips
    line = PlanPhaseTrailer.line(REF)
    assert_equal "Plan-Phase: #{REF}", line
    assert_equal REF, PlanPhaseTrailer.parse("Body\n\n#{line}\n")
  end

  def test_line_rejects_a_bad_ref
    assert_raises(ArgumentError) { PlanPhaseTrailer.line("demo-area/widget-plan#Phase 0") }
    assert_raises(ArgumentError) { PlanPhaseTrailer.line(nil) }
  end
end
