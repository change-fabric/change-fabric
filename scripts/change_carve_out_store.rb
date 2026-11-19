#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'change_receipt_store'

# Phone-approved carve-out merges, keyed by repo, PR number and the exact head
# sha the phone showed. A new head needs a new approval. The merge guard reads
# it with `lookup` (P4); ApprovalConsole::Recorder is the only writer.
class ChangeCarveOutStore < ChangeReceiptStore
  DIR = 'carve_outs'

  def record(repo:, pr:, sha:, proof:, policy_sha:, recorded_by:)
    write({ repo: repo, pr: pr, sha: sha }, proof: proof, policy_sha: policy_sha, recorded_by: recorded_by)
  end

  def lookup(repo:, pr:, sha:) = read(repo: repo, pr: pr, sha: sha)
end
