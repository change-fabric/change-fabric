# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_k6_narrative"

class ChangeK6NarrativeTest < Minitest::Test
  def test_absent_scenario_renders_nothing
    assert_nil ChangeK6Narrative.section(nil)
    assert_nil ChangeK6Narrative.section({})
  end

  def test_funnel_derives_expected_peak
    scenario = {
      "window" => "per minute",
      "funnel" => [
        { "stage" => "emails", "value" => 100_000 },
        { "stage" => "opened", "rate" => 0.25 },
        { "stage" => "clicked", "rate" => 0.10 },
        { "stage" => "attempted", "rate" => 0.05 }
      ]
    }
    section = ChangeK6Narrative.section(scenario)
    assert_includes section, "## Load test narrative"
    # 100000 * 0.25 * 0.10 * 0.05 = 125
    assert_includes section, "Expected peak: about 125 per minute."
  end

  def test_safety_margin_computed_from_tested_rate
    scenario = {
      "expected_peak" => "125 per minute",
      "tested_rate" => 18_000
    }
    section = ChangeK6Narrative.section(scenario)
    # 18000 / 125 = 144
    assert_includes section, "roughly 144x the expected peak"
  end

  def test_stated_margin_used_when_no_tested_rate
    scenario = { "expected_peak" => "10 per minute", "safety_margin" => "well over 100x" }
    section = ChangeK6Narrative.section(scenario)
    assert_includes section, "Safety margin: well over 100x."
  end

  def test_optional_prose_parts_render_when_present
    scenario = {
      "overload" => "queued and drained in 8s",
      "comparison" => "a well-known launch",
      "tested_to" => "300 rps zero errors"
    }
    section = ChangeK6Narrative.section(scenario)
    assert_includes section, "Deliberate over-the-ceiling burst: queued and drained in 8s."
    assert_includes section, "For scale: a well-known launch."
    assert_includes section, "Tested to: 300 rps zero errors."
  end
end
