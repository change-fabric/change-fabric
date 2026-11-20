# frozen_string_literal: true

require_relative "deep_research_helper"

class DeepResearchParseTest < Minitest::Test
  include DeepResearchHelper

  def parse(*entries) = DeepResearchParse.parse(xml(*entries))

  def skeleton(findings, sources)
    [ "Summary", "A summary. [1]", "Findings", *findings, "Sources", *sources, "Unverified", "Contested" ]
  end

  def test_synthetic_fixture_pairs_footnotes_with_links
    parsed = DeepResearchParse.parse(File.read(fixture("synthetic", "raw.xml")))
    assert_equal [ %w[S1], %w[S2 S3], %w[S3], %w[S3], %w[S2] ], parsed[:findings].map { |f| f["source_ids"] }
    assert_equal %w[contested], parsed[:findings].map { |f| f["status"] }.grep("contested")
    assert_equal "full", parsed[:link_annotations]
    assert_equal "plain text diffs cleanly", parsed[:findings][0]["quote"]
    assert_empty parsed[:diagnostics]
  end

  def test_synthetic_fixture_report_json_matches
    expected = JSON.parse(File.read(fixture("synthetic", "report.json")))
    parsed = DeepResearchParse.parse(File.read(fixture("synthetic", "raw.xml")))
    assert_equal expected["findings"].map { |f| f.slice("id", "claim", "source_ids", "quote", "status") },
                 parsed[:findings].map { |f| f.slice("id", "claim", "source_ids", "quote", "status") }
    assert_equal expected["sources"], parsed[:sources]
    assert_equal expected["citations"], parsed[:citations]
  end

  def test_missing_heading_fails_closed_with_a_diagnostic
    parsed = parse("Summary", "Text.", "Findings", "1. Claim. [1]")
    assert_includes parsed[:diagnostics], "missing heading: sources"
    assert_equal [ [] ], parsed[:findings].map { |f| f["source_ids"] }
    assert_includes parsed[:diagnostics], "F1: footnote 1 has no source"
  end

  def test_wrapped_citation_joins_into_one_finding
    parsed = parse(*skeleton([ "1. A claim that wraps", "onto a second line. [1]" ],
                             [ [ "1. Doc https://example.org/a", "https://example.org/a" ] ]))
    assert_equal [ "A claim that wraps onto a second line. [1]" ], parsed[:findings].map { |f| f["claim"] }
    assert_equal [ %w[S1] ], parsed[:findings].map { |f| f["source_ids"] }
  end

  def test_duplicate_source_number_is_dropped_and_never_paired
    parsed = parse(*skeleton([ "1. Claim. [1]" ],
                             [ [ "1. One https://example.org/a", "https://example.org/a" ],
                               [ "1. Two https://example.org/b", "https://example.org/b" ] ]))
    assert_includes parsed[:diagnostics], "duplicate source number: 1"
    assert_empty parsed[:sources]
    assert_equal [ [] ], parsed[:findings].map { |f| f["source_ids"] }
  end

  def test_ambiguous_finding_boundary_keeps_one_unverified_finding
    parsed = parse(*skeleton([ "No numbering here.", "Still the same." ], []))
    assert_includes parsed[:diagnostics], "ambiguous finding boundary"
    assert_equal [ "No numbering here. Still the same." ], parsed[:findings].map { |f| f["claim"] }
    assert_equal [ "unverified" ], parsed[:findings].map { |f| f["status"] }
  end

  def test_inline_link_chip_becomes_a_source
    parsed = parse(*skeleton([ [ "1. Claim (example.org)", "https://example.org/chip" ] ], []))
    assert_equal [ "https://example.org/chip" ], parsed[:sources].map { |s| s["url"] }
    assert_equal [ %w[S1] ], parsed[:findings].map { |f| f["source_ids"] }
  end

  def test_no_link_annotations_is_reported_and_urls_in_text_still_count
    parsed = parse(*skeleton([ "1. Claim. [1]" ], [ "1. Doc https://example.org/a" ]))
    assert_equal "none", parsed[:link_annotations]
    assert_equal [ "https://example.org/a" ], parsed[:sources].map { |s| s["url"] }
  end

  def test_partial_when_only_some_sources_carry_links
    parsed = parse(*skeleton([ "1. Claim. [1, 2]" ],
                             [ [ "1. A https://example.org/a", "https://example.org/a" ], "2. B https://example.org/b" ]))
    assert_equal "partial", parsed[:link_annotations]
  end

  def test_summary_markers_become_summary_citations
    parsed = parse(*skeleton([ "1. Claim." ], [ [ "1. A https://example.org/a", "https://example.org/a" ] ]))
    cite = parsed[:citations].find { |c| c["finding_id"] == "summary" }
    assert_equal({ "basis" => "summary", "start" => 11, "end" => 14 }, cite["span"])
  end

  def test_internal_non_http_links_are_ignored
    parsed = parse(*skeleton([ [ "1. Claim. [1]", "#page2" ] ], [ "1. A https://example.org/a" ]))
    assert_equal [ %w[S1] ], parsed[:findings].map { |f| f["source_ids"] }
    assert_equal 1, parsed[:sources].size
  end

  def test_entities_are_decoded
    parsed = parse(*skeleton([ "1. Quote &#34;a &amp; b&#34; here. [1]" ], [ "1. A https://example.org/a" ]))
    assert_equal "a & b", parsed[:findings][0]["quote"]
  end

  # The real ChatGPT export fixture. Defined only once the fixture is committed
  # (the plan forbids merging P1 without it); it is never skipped or pending.
  if File.exist?(File.join(DeepResearchHelper::FIXTURES, "chatgpt", "report.json"))
    def test_chatgpt_fixture_matches_its_expected_report
      expected = JSON.parse(File.read(fixture("chatgpt", "report.json")))
      parsed = DeepResearchParse.parse(File.read(fixture("chatgpt", "raw.xml")))
      assert_equal expected["sources"], parsed[:sources]
      assert_equal expected["findings"].map { |f| f["source_ids"] }, parsed[:findings].map { |f| f["source_ids"] }
      assert_equal expected["summary"], parsed[:summary]
    end
  end
end
