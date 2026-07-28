# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"

require_relative "../scripts/history_scrub"

class HistoryScrubTest < Minitest::Test
  def with_terms_file(contents)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sensitive_terms.txt")
      File.write(path, contents)
      yield path
    end
  end

  def terms_for(path, extra: [])
    HistoryScrub::TermList.new(terms_path: path, extra: extra).terms
  end

  def test_reads_terms_ignoring_comments_and_blanks
    with_terms_file("# note\n\nacme corp\nacmestaging.org\n") do |path|
      assert_equal [ "acme corp", "acmestaging.org" ], terms_for(path)
    end
  end

  def test_merges_and_dedupes_ad_hoc_terms
    with_terms_file("acme corp\n") do |path|
      assert_equal [ "acme corp", "widgetco" ], terms_for(path, extra: [ "widgetco", " acme corp " ])
    end
  end

  def test_no_terms_when_file_missing
    Dir.mktmpdir do |dir|
      assert_empty terms_for(File.join(dir, "nope.txt"))
    end
  end

  def test_run_refuses_without_terms
    Dir.mktmpdir do |dir|
      err = StringIO.new
      status = HistoryScrub.run([ "--terms-file", File.join(dir, "nope.txt") ], stdout: StringIO.new, stderr: err)
      assert_equal 1, status
      assert_includes err.string, "no terms to scrub"
    end
  end

  def test_rejects_unknown_flag
    err = StringIO.new
    assert_nil HistoryScrub.parse_args([ "--bogus" ], err)
    assert_includes err.string, "usage: history_scrub.rb"
  end

  def test_defaults_to_analysis_only
    options = HistoryScrub.parse_args([], StringIO.new)
    refute options[:rewrite]
    assert_equal HistoryScrub::DEFAULT_REPLACEMENT, options[:replacement]
  end

  def test_rewrite_flag_and_overrides_parse
    options = HistoryScrub.parse_args([ "--rewrite", "--term", "a", "--term", "b", "--replacement", "X" ], StringIO.new)
    assert options[:rewrite]
    assert_equal [ "a", "b" ], options[:terms]
    assert_equal "X", options[:replacement]
  end

  def rule_for(term, replacement: "REDACTED")
    HistoryScrub::Rewriter.new([ term ], filter_repo: "/bin/true", replacement: replacement)
                          .send(:rule, term)
  end

  def test_rule_is_case_insensitive_and_escapes_domains
    assert_equal "regex:(?i)acmestaging\\.org==>REDACTED", rule_for("acmestaging.org")
  end

  def test_rule_escapes_spaces_and_punctuation
    assert_equal "regex:(?i)acme\\ corp\\-x==>GONE", rule_for("acme corp-x", replacement: "GONE")
  end

  def test_scanner_counts_case_insensitive_substrings
    scanner = HistoryScrub::Scanner.new([ "acme" ])
    counts = Hash.new(0)
    found = scanner.send(:tally, "ACME and acmestaging.org and Acme", counts)
    assert_equal 3, found
    assert_equal 3, counts["acme"]
  end

  def test_report_empty_when_no_occurrences
    assert HistoryScrub::Report.new([], [], { "acme" => 0 }).empty?
    refute HistoryScrub::Report.new([ "abc" ], [], { "acme" => 1 }).empty?
  end

  def test_preflight_flags_dirty_or_non_repo_tree
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { assert_includes HistoryScrub::Preflight.new.blocker.to_s, "work tree" }
    end
  end
end
