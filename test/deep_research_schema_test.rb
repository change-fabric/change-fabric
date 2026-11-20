# frozen_string_literal: true

require_relative "deep_research_helper"

class DeepResearchSchemaTest < Minitest::Test
  include DeepResearchHelper

  def good = JSON.parse(File.read(fixture("synthetic", "report.json")))

  def test_synthetic_fixture_report_is_valid
    assert_equal [], DeepResearchSchema.validate(good)
  end

  def test_rejects_non_object_and_missing_keys
    refute DeepResearchSchema.valid?("x")
    report = good.tap { |r| r.delete("summary") }
    assert_includes DeepResearchSchema.validate(report), "summary must be a string"
  end

  def test_null_in_a_non_nullable_field_fails
    report = good.tap { |r| r["findings"][0]["claim"] = nil }
    assert_includes DeepResearchSchema.validate(report), "findings[0].claim must be a string"
  end

  def test_unknown_status_fails_and_quote_may_be_null
    report = good.tap { |r| r["findings"][0]["status"] = "trusted"; r["findings"][1]["quote"] = nil }
    errors = DeepResearchSchema.validate(report)
    assert_includes errors, "findings[0].status unknown"
    refute(errors.any? { |e| e.include?("quote") })
  end

  def test_unresolved_ids_fail
    report = good.tap do |r|
      r["findings"][0]["source_ids"] = [ "S9" ]
      r["citations"] << { "finding_id" => "F9", "source_id" => "S1", "span" => nil }
    end
    errors = DeepResearchSchema.validate(report)
    assert_includes errors, "findings[0].source_ids S9 does not resolve"
    assert(errors.any? { |e| e.include?("finding_id does not resolve") })
  end

  def test_span_outside_its_text_fails_and_summary_finding_id_is_allowed
    report = good.tap do |r|
      r["citations"] << { "finding_id" => "summary", "source_id" => "S1",
                          "span" => { "basis" => "summary", "start" => 0, "end" => 9999 } }
    end
    assert(DeepResearchSchema.validate(report).any? { |e| e.include?("span is outside its text") })
    report["citations"].last["span"]["end"] = 5
    assert_equal [], DeepResearchSchema.validate(report)
  end

  def test_cost_and_provenance_contract
    report = good.tap { |r| r["cost"] = { "usd" => 3.1 }; r["provenance"].delete("response_id") }
    errors = DeepResearchSchema.validate(report)
    assert(errors.any? { |e| e.start_with?("cost must be") })
    assert_includes errors, "provenance.response_id must be present (null allowed)"
  end
end
