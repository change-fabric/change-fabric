# frozen_string_literal: true

require_relative "test_helpers"
require_relative "../scripts/review_findings"
require_relative "../scripts/review_prompt"

class ReviewFindingsTest < Minitest::Test
  include SkillTempHome
  include SkillFactory

  def finding(extra = {})
    { "kind" => "scope_creep", "file" => "a.rb", "line" => 3, "summary" => "renames an unrelated helper" }.merge(extra)
  end

  def test_empty_findings_are_valid
    accepted, rejected = ReviewFindings.validate([])
    assert_empty accepted
    assert_empty rejected
  end

  def test_a_cited_finding_is_accepted
    accepted, rejected = ReviewFindings.validate([ finding ])
    assert_equal 1, accepted.size
    assert_empty rejected
  end

  def test_a_finding_without_file_and_line_is_rejected
    _accepted, rejected = ReviewFindings.validate([ finding("file" => ""), finding("line" => 0), finding("line" => "3") ])
    assert_equal 3, rejected.size
  end

  def test_an_unknown_kind_is_rejected
    _accepted, rejected = ReviewFindings.validate([ finding("kind" => "vibes") ])
    assert_includes rejected.first[:reason], "kind must be one of"
  end

  def test_add_abstraction_without_a_second_caller_is_rejected
    accepted, rejected = ReviewFindings.validate([ finding("kind" => "add_abstraction"), finding("kind" => "add_abstraction", "second_caller" => "soon") ])
    assert_empty accepted
    assert_equal 2, rejected.size
    assert_includes rejected.first[:reason], "second_caller"
  end

  def test_add_abstraction_with_a_second_caller_that_exists_is_accepted
    accepted, = ReviewFindings.validate([ finding("kind" => "add_abstraction", "second_caller" => "b.rb:12") ])
    assert_equal 1, accepted.size
  end

  def test_a_non_array_is_rejected
    accepted, rejected = ReviewFindings.validate({ "kind" => "scope_creep" })
    assert_empty accepted
    assert_equal 1, rejected.size
  end

  def test_record_logs_accepted_and_rejected_rows_to_the_jsonl
    path = File.join(@home, "findings.jsonl")
    ENV["CF_REVIEW_FINDINGS_PATH"] = path
    ReviewFindings.record([ finding, finding("kind" => "add_abstraction") ], session: "s1")
    rows = File.readlines(path).map { |line| JSON.parse(line) }
    assert_equal [ true, false ], rows.map { |row| row["accepted"] }
    assert_equal "s1", rows.first["session"]
    assert_equal "a.rb", rows.first["file"]
    assert_includes rows.last["reason"], "second_caller"
  ensure
    ENV.delete("CF_REVIEW_FINDINGS_PATH")
  end

  def test_default_path_is_under_the_cf_state_dir
    assert_equal "review_findings.jsonl", File.basename(ReviewFindings.path)
  end

  def test_the_stage2_prompt_lists_the_judgment_items_and_the_contract
    @skills = Dir.mktmpdir
    registry = SkillRegistry.load(@skills)
    text = ReviewPrompt.stage2([ { skill: "ruby", path: "/p/a.rb", hash: "h" } ], registry, "s1")
    ReviewPrompt::JUDGMENT_ITEMS.each { |item| assert_includes text, item }
    assert_includes text, "N+1"
    assert_includes text, "An empty array is a valid answer"
    assert_includes text, "second_caller"
    assert_includes text, ReviewPrompt::REVIEWER, "the host rewrites this to the worker role"
    assert_includes text, "review_findings.rb s1"
    assert_includes text, "review_ack.rb s1"
  ensure
    FileUtils.remove_entry(@skills)
  end
end
