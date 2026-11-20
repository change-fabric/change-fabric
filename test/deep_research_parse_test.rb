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

  def marked(number, text) = { frags: [ [ "#{number}. ", 10 ], [ text, 40 ] ] }

  def test_ref_tokens_pair_with_sources_that_carry_the_same_ref_even_when_wrapped
    token = "【"
    parsed = parse("Summary", "Short.", "Findings",
                   marked(1, "Claim one #{token}"), { frags: [ [ "42†L1-", 40 ] ] }, "L9】.",
                   "Sources", marked(1, "Doc A: note. URL: https://example.org/a 【42†L1-L9】"),
                   "Unverified", "Contested")
    assert_equal [ %w[S1] ], parsed[:findings].map { |f| f["source_ids"] }
    assert_equal "Claim one【42†L1-L9】.", parsed[:findings][0]["claim"]
    assert_equal "Doc A", parsed[:sources][0]["title"]
  end

  def test_url_wrapped_across_lines_rejoins
    parsed = parse("Sources", marked(1, "Doc URL: https://"), "www.example.org/articles/", "page 【42†L1-L2】")
    assert_equal [ "https://www.example.org/articles/page" ], parsed[:sources].map { |s| s["url"] }
  end

  def test_a_ref_whose_source_has_no_url_is_named_in_a_diagnostic
    parsed = parse("Findings", marked(1, "Claim 【27†L1-L2】."), "Sources", marked(1, "Blog post 【27†L1-L2】"))
    assert_empty parsed[:sources]
    assert_includes parsed[:diagnostics], "F1: ref 27 belongs to source 1, which has no URL"
    assert_equal [ [] ], parsed[:findings].map { |f| f["source_ids"] }
  end

  def test_a_ref_with_no_source_entry_fails_closed
    parsed = parse("Findings", marked(1, "Claim 【52†L1-L2】."), "Sources")
    assert_includes parsed[:diagnostics], "F1: ref 52 has no source entry"
  end

  def test_a_none_reply_under_contested_is_not_a_finding
    parsed = parse("Findings", marked(1, "Claim."), "Contested", { frags: [ [ "•", 10 ], [ "We found no direct contradictions.", 40 ] ] })
    assert_equal [ "F1" ], parsed[:findings].map { |f| f["id"] }
    assert_includes parsed[:diagnostics], "contested section reports none"
  end

  def test_page_number_footer_and_wrapped_hyphen_words
    page = xml(marked(1, "version-"), "controlled text.").sub("</page>", %(<text top="9500" left="400" width="1" height="1" font="5">7</text></page>))
    lines = DeepResearchParse.lines(page)
    assert_equal 2, lines.size
    assert_equal "version-controlled text.", DeepResearchParse.join(lines.map(&:text))
  end

  def test_negative_claims_with_citations_stay_findings_under_unverified
    parsed = parse("Unverified", marked(1, "None of the providers publish retention limits. [1]"),
                   marked(2, "We found no evidence of encryption. [2]"), marked(3, "None."))
    assert_equal [ "None of the providers publish retention limits. [1]", "We found no evidence of encryption. [2]" ],
                 parsed[:findings].map { |f| f["claim"] }
    assert_includes parsed[:diagnostics], "unverified section reports none"
  end

  def test_a_ref_shared_by_sources_with_different_urls_is_left_unresolved
    token = "【42†L1-L2】"
    parsed = parse("Findings", marked(1, "Claim #{token}."), "Sources",
                   marked(1, "A URL: https://example.org/a #{token}"), marked(2, "B URL: https://example.org/b #{token}"))
    assert_equal [ [] ], parsed[:findings].map { |f| f["source_ids"] }
    assert_equal 1, parsed[:findings][0]["unresolved_citations"]
    assert_includes parsed[:diagnostics], "F1: ref 42 maps to conflicting sources 1, 2; left unresolved"
  end

  def test_a_partly_unresolved_citation_is_not_marked_resolved
    parsed = parse("Findings", marked(1, "Claim. [1, 9]"), "Sources", marked(1, "A URL: https://example.org/a"))
    report = DeepResearchVerify.annotate("sources" => parsed[:sources], "findings" => parsed[:findings])
    assert_equal [ %w[S1] ], report["findings"].map { |f| f["source_ids"] }
    assert_equal 1, report["findings"][0]["unresolved_citations"]
    assert_equal false, report["findings"][0]["citation_resolves"]
  end

  def test_url_wrapped_after_a_query_delimiter_rejoins
    parsed = parse("Sources", marked(1, "Doc URL: https://example.org/search?q="), "ruby&page=2",
                   marked(2, "Doc2 URL: https://example.org/a#"), "frag")
    assert_equal [ "https://example.org/search?q=ruby&page=2", "https://example.org/a#frag" ],
                 parsed[:sources].map { |src| src["url"] }
  end

  def test_inline_and_marker_numbered_sources_can_mix_in_one_section
    parsed = parse("Sources", "1. First https://example.org/first", marked(2, "Second https://example.org/second"),
                   "2011): wrapped line that starts with digits")
    assert_equal %w[S1 S2], parsed[:sources].map { |src| src["id"] }
    assert_includes parsed[:sources][1]["title"], "Second"
  end

  def test_a_linked_summary_keeps_its_citation
    parsed = parse("Summary", [ "Linked summary.", "https://example.org/a" ], "Sources", marked(1, "A https://example.org/a"))
    cite = parsed[:citations].find { |c| c["finding_id"] == "summary" }
    assert_equal({ "finding_id" => "summary", "source_id" => "S1", "span" => nil }, cite)
  end

  def test_balanced_parentheses_in_a_url_survive_and_prose_punctuation_is_stripped
    parsed = parse("Sources", marked(1, "Ruby https://en.wikipedia.org/wiki/Ruby_(programming_language)."),
                   marked(2, "(see https://example.org/a)"))
    assert_equal [ "https://en.wikipedia.org/wiki/Ruby_(programming_language)", "https://example.org/a" ],
                 parsed[:sources].map { |src| src["url"] }
  end

  # The real ChatGPT export fixture (Patrick's first manual run). The export
  # holds the report only: no prompt, no run id, no link annotations.
  def test_chatgpt_fixture_matches_its_expected_report
    expected = JSON.parse(File.read(fixture("chatgpt", "report.json")))
    parsed = DeepResearchParse.parse(File.read(fixture("chatgpt", "raw.xml")))
    assert_equal expected["sources"], parsed[:sources]
    assert_equal expected["findings"].map { |f| f["source_ids"] }, parsed[:findings].map { |f| f["source_ids"] }
    assert_equal expected["summary"], parsed[:summary]
    assert_equal "none", parsed[:link_annotations]
    assert_equal [ 16, 11 ], [ parsed[:findings].size, parsed[:sources].size ]
    assert_equal 11, parsed[:findings].count { |f| f["source_ids"].any? }
  end
end
