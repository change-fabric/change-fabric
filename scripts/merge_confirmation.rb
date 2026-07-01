#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'

# Decides whether the single narrow auto-delete exception in pst:prune step 7
# applies: the branch that was HEAD in the host worktree this session, already
# classified prunable/squash_merged by BranchClassify, gets one more check
# against GitHub itself before its remote ref can go without an
# AskUserQuestion. Every other remote branch still goes through the Asking
# table unchanged. evaluate is pure (no shell-out) so it is unit-testable
# without mocking gh; the CLI class does the actual gh pr view call.
module MergeConfirmation
  Result = Data.define(:confirmed, :reason, :pr_number)

  module_function

  # branch/kind come from BranchClassify. gh_status is the exit success? of the
  # `gh pr view` call; gh_json is its stdout. Fails closed: any gh error,
  # network issue, or missing auth yields confirmed: false, same as a real
  # mismatch. pr_number carries the PR number through so a caller can report it
  # as evidence without a second gh call; it is nil whenever confirmed is false.
  def evaluate(branch:, kind:, gh_json:, gh_status:)
    return Result.new(confirmed: false, reason: 'not_content_merged', pr_number: nil) unless %w[prunable squash_merged].include?(kind)
    return Result.new(confirmed: false, reason: 'gh_lookup_failed', pr_number: nil) unless gh_status

    pr = JSON.parse(gh_json)
    return Result.new(confirmed: false, reason: 'not_merged', pr_number: nil) unless pr['state'] == 'MERGED'
    return Result.new(confirmed: false, reason: 'head_ref_mismatch', pr_number: nil) unless pr['headRefName'] == branch

    Result.new(confirmed: true, reason: 'verified_current_branch_merged_pr', pr_number: pr['number'])
  rescue JSON::ParserError
    Result.new(confirmed: false, reason: 'gh_lookup_failed', pr_number: nil)
  end

  # Errno::ENOENT covers gh missing from PATH; other Open3/system errors also
  # count as a lookup failure so the CLI never crashes instead of failing closed.
  def gh_pr_view(branch)
    Open3.capture2e('gh', 'pr', 'view', branch, '--json', 'state,headRefName,number')
  rescue SystemCallError
    [ '', Struct.new(:success?).new(false) ]
  end

  class CLI
    def self.run(argv, out: $stdout)
      branch, kind = argv
      return out.puts('usage: merge_confirmation.rb <branch> <kind>') if branch.to_s.empty? || kind.to_s.empty?

      gh_json, status = MergeConfirmation.gh_pr_view(branch)
      result = MergeConfirmation.evaluate(branch:, kind:, gh_json:, gh_status: status.success?)
      out.puts(JSON.generate(result.to_h))
    end
  end
end

MergeConfirmation::CLI.run(ARGV) if __FILE__ == $PROGRAM_NAME
