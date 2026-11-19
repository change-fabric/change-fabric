# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../scripts/roast_followups"

class RoastFollowupsTest < Minitest::Test
  ISSUES = [
    { "priority" => "P2", "where" => "a", "problem" => "minor", "fix" => "f" },
    { "priority" => "P1", "where" => "hero", "problem" => "No clear action", "fix" => "One button" }
  ].freeze
  CRITIC = { "score" => 8, "issues" => ISSUES }.freeze

  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "round-1.response.json")
  end

  def teardown = FileUtils.rm_rf(@dir)

  def entries = RoastFollowups.from_critic(1, CRITIC)

  def test_id_is_stable_and_uses_index_and_content_hash
    id = entries.first["id"]
    assert_match(/\Ar1-i1-[0-9a-f]{8}\z/, id)
    assert_equal id, RoastFollowups.from_critic(1, CRITIC).first["id"]
    other = { "issues" => [ ISSUES[0], ISSUES[1].merge("problem" => "changed") ] }
    refute_equal id, RoastFollowups.from_critic(1, other).first["id"]
  end

  def test_only_p1_issues_become_pending_entries
    assert_equal 1, entries.size
    entry = entries.first
    assert_equal "P1", entry["priority"]
    assert_equal "pending", entry["outcome"]
    assert_equal 0, entry["attempts"]
    assert_nil entry["judge_verdict"]
    assert_nil entry["escalation_reason"]
  end

  def test_decide_before_response_creates_the_file_and_later_responses_merge_in
    RoastFollowups.upsert(@path, entries)
    data = JSON.parse(File.read(@path))
    assert_equal [], data["responses"]
    assert_equal 1, data["followups"].size
    data["responses"] << { "verdict" => "accept" }
    File.write(@path, JSON.generate(data))
    RoastFollowups.upsert(@path, entries)
    assert_equal [ { "verdict" => "accept" } ], JSON.parse(File.read(@path))["responses"]
  end

  def test_response_before_decide_preserves_the_responses
    File.write(@path, JSON.generate("responses" => [ { "verdict" => "rebut", "x" => 1 } ]))
    RoastFollowups.upsert(@path, entries)
    data = JSON.parse(File.read(@path))
    assert_equal [ { "verdict" => "rebut", "x" => 1 } ], data["responses"]
    assert_equal 1, data["followups"].size
  end

  def test_decide_rerun_after_mitigation_keeps_the_outcome_and_never_duplicates
    RoastFollowups.upsert(@path, entries)
    done = entries.first.merge("outcome" => "mitigated", "judge_verdict" => "resolved", "attempts" => 1, "note" => "fixed")
    RoastFollowups.upsert(@path, [ done ])
    stored = RoastFollowups.upsert(@path, entries)
    assert_equal 1, stored.size
    assert_equal "mitigated", stored.first["outcome"]
    assert_equal 1, stored.first["attempts"]
    assert_equal "fixed", stored.first["note"]
  end

  def test_update_by_id_changes_fields_in_place
    RoastFollowups.upsert(@path, entries)
    id = entries.first["id"]
    RoastFollowups.upsert(@path, [ { "id" => id, "outcome" => "escalated", "escalation_reason" => "taste call" } ])
    stored = RoastFollowups.followups(@path)
    assert_equal 1, stored.size
    assert_equal "escalated", stored.first["outcome"]
    assert_equal "taste call", stored.first["escalation_reason"]
    assert_equal "hero", stored.first["where"]
  end

  def test_invalid_outcome_is_rejected_and_nothing_is_written
    bad = entries.first.merge("outcome" => "done")
    err = assert_raises(RoastFollowups::InvalidEntry) { RoastFollowups.upsert(@path, [ bad ]) }
    assert_includes err.message, "invalid outcome"
    refute File.exist?(@path)
    assert_raises(RoastFollowups::InvalidEntry) { RoastFollowups.upsert(@path, [ entries.first.merge("attempts" => 3) ]) }
    assert_raises(RoastFollowups::InvalidEntry) { RoastFollowups.upsert(@path, [ entries.first.merge("judge_verdict" => "maybe") ]) }
  end
end
