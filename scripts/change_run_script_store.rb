#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'change_receipt_store'

# Phone-approved script runs, keyed by repo, the script's SHA-256 and the
# commit it targets. cf_run_approved.rb reads it with `lookup`;
# ApprovalConsole::Recorder is the only writer.
class ChangeRunScriptStore < ChangeReceiptStore
  DIR = 'run-scripts'

  def record(repo:, script_sha256:, sha:, proof:, policy_sha:, recorded_by:)
    write({ repo: repo, script_sha256: script_sha256, sha: sha }, proof: proof, policy_sha: policy_sha, recorded_by: recorded_by)
  end

  def lookup(repo:, script_sha256:, sha:) = read(repo: repo, script_sha256: script_sha256, sha: sha)
end
