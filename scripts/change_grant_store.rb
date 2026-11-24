#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'change_receipt_store'

# Phone-approved grants (pulse's standing permissions), keyed by repo and the
# SHA-256 of the signed body. ApprovalConsole::Recorder is the only writer;
# pulse_grants.rb reads every record with `all` and re-verifies each proof, so
# a file placed here by anything else never counts.
class ChangeGrantStore < ChangeReceiptStore
  DIR = 'grants'

  def record(repo:, grant_id:, proof:, policy_sha:, recorded_by:)
    write({ repo: repo, grant_id: grant_id }, proof: proof, policy_sha: policy_sha, recorded_by: recorded_by)
  end

  def lookup(repo:, grant_id:) = read(repo: repo, grant_id: grant_id)

  # Every parseable record on disk, valid or not; the reader verifies them.
  def all
    Dir.glob(File.join(@root, '*.json')).filter_map do |file|
      record = JSON.parse(File.read(file))
      record if record.is_a?(Hash)
    rescue JSON::ParserError, SystemCallError
      nil
    end
  end
end
