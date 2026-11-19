#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'change_receipt_store'

# Phone-approved releases, keyed by repo, tag and the exact commit the tag
# points at. The tag guard reads it with `lookup` (P5);
# ApprovalConsole::Recorder is the only writer.
class ChangeReleaseStore < ChangeReceiptStore
  DIR = 'releases'

  def record(repo:, tag:, sha:, proof:, policy_sha:, recorded_by:)
    write({ repo: repo, tag: tag, sha: sha }, proof: proof, policy_sha: policy_sha, recorded_by: recorded_by)
  end

  def lookup(repo:, tag:, sha:) = read(repo: repo, tag: tag, sha: sha)
end
