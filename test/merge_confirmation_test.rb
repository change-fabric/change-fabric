# frozen_string_literal: true

require_relative "test_helpers"
require_relative "#{SKILL_SCRIPTS}/merge_confirmation"
require "json"
require "open3"

class MergeConfirmationTest < Minitest::Test
  def merged_json(head_ref: "feature", state: "MERGED")
    JSON.generate("state" => state, "headRefName" => head_ref, "number" => 1)
  end

  # Swaps Open3.capture2e for one that raises ENOENT, matching a missing gh
  # binary, without minitest/mock (absent from this bundle).
  def with_missing_gh
    original = Open3.method(:capture2e)
    verbose = $VERBOSE
    $VERBOSE = nil
    Open3.singleton_class.send(:define_method, :capture2e) { |*| raise Errno::ENOENT, "gh" }
    yield
  ensure
    Open3.singleton_class.send(:define_method, :capture2e, &original)
    $VERBOSE = verbose
  end

  def test_confirmed_true_for_squash_merged_matching_current_branch
    result = MergeConfirmation.evaluate(branch: "feature", kind: "squash_merged",
                                         gh_json: merged_json, gh_status: true)
    assert result.confirmed
    assert_equal "verified_current_branch_merged_pr", result.reason
    assert_equal 1, result.pr_number
  end

  def test_confirmed_false_when_kind_is_rogue
    result = MergeConfirmation.evaluate(branch: "feature", kind: "rogue",
                                         gh_json: merged_json, gh_status: true)
    refute result.confirmed
    assert_equal "not_content_merged", result.reason
  end

  def test_confirmed_false_when_state_is_open
    result = MergeConfirmation.evaluate(branch: "feature", kind: "prunable",
                                         gh_json: merged_json(state: "OPEN"), gh_status: true)
    refute result.confirmed
    assert_equal "not_merged", result.reason
  end

  def test_confirmed_false_when_head_ref_differs
    result = MergeConfirmation.evaluate(branch: "feature", kind: "prunable",
                                         gh_json: merged_json(head_ref: "someone-elses-branch"), gh_status: true)
    refute result.confirmed
    assert_equal "head_ref_mismatch", result.reason
  end

  def test_confirmed_false_when_gh_lookup_failed
    result = MergeConfirmation.evaluate(branch: "feature", kind: "prunable",
                                         gh_json: "", gh_status: false)
    refute result.confirmed
    assert_equal "gh_lookup_failed", result.reason
  end

  def test_confirmed_false_when_gh_json_is_malformed
    result = MergeConfirmation.evaluate(branch: "feature", kind: "prunable",
                                         gh_json: "not json", gh_status: true)
    refute result.confirmed
    assert_equal "gh_lookup_failed", result.reason
  end

  def test_gh_pr_view_missing_binary_fails_closed
    with_missing_gh do
      _json, status = MergeConfirmation.gh_pr_view("feature")
      refute status.success?
    end
  end
end
