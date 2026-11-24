#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'approval_console/canonical'
require_relative 'approval_console/local_store'
require_relative 'approval_console/proof_check'
require_relative 'approval_console/recorder'
require_relative 'approval_console/remote'
require_relative 'change_policy'
require_relative 'change_grant_store'
require_relative 'cf_project_identity'

# Pulse's standing permissions (C3, decision 5). A grant is a phone-approved
# console receipt of type `grant`; this reads them and never writes one (the
# only writer is ApprovalConsole::Recorder, after a phone tap). Every record
# is re-verified on every read against the repository's authoritative approval_pins
# (the default branch's policy, fetched once per instance; unreadable means no grants), so a hand-edited or hand-made file counts for nothing.
#
# A grant stands only when all of these hold:
#   - the proof verifies as a console receipt of kind webauthn+totp for exactly
#     its signed body (any edit to scope, expiry or repo breaks the receipt);
#   - the signed repo is this project and the signed machine is this machine;
#   - now is before the signed grant_expires_at (no skew allowance on expiry);
#   - the receipt was accepted inside the request's own window, give or take
#     the five-minute skew `ProofCheck` allows, and not in the future.
class PulseGrants
  Grant = Struct.new(:id, :scope_list, :expires_at, :accepted_at, keyword_init: true)

  attr_reader :rejected

  # `rejected` maps a record's grant id (or its file position) to why it was
  # refused, so a denial can name the reason.
  def initialize(project: Dir.pwd, store: ApprovalConsole::LocalStore.new, grants: ChangeGrantStore.new, now: Time.now, project_id: nil, pins: :authoritative)
    @project = project
    @pins = pins
    @project_id = project_id
    @store = store
    @grants = grants
    @now = now
    @rejected = {}
  end

  def active
    @rejected = {}
    @grants.all.each_with_index.filter_map { |record, index| load_grant(record, index) }
  end

  def allows?(action) = active.any? { |grant| grant.scope_list.include?(action.to_s) }

  # Why an action is not covered, for a denial: the first refusal of a record
  # that does cover it (an expired grant, say), else nil.
  def refusal_for(action)
    active
    @rejected.values.find { |entry| entry[:scope_list].include?(action.to_s) }&.fetch(:reason)
  end

  private

  def load_grant(record, index)
    body = parse_body(record)
    id = body ? ApprovalConsole::Canonical.body_sha256(record['proof']['body']) : "record-#{index}"
    reason = body ? problem(record, body, id) : 'malformed'
    return Grant.new(id: id, scope_list: body['scope_list'], expires_at: Time.iso8601(body['grant_expires_at']), accepted_at: accepted(record)) unless reason

    @rejected[id] = { reason: reason, scope_list: body ? body['scope_list'] : [] }
    nil
  end

  def parse_body(record)
    proof = record['proof']
    text = proof.is_a?(Hash) ? proof['body'] : nil
    return nil unless text.is_a?(String)

    body = ApprovalConsole::Canonical.parse(text)
    body if body['type'] == 'grant'
  rescue ApprovalConsole::Canonical::Invalid
    nil
  end

  def problem(record, body, id)
    return 'wrong-project' unless body['repo'] == (@project_id || CfProjectIdentity.for(@project).id) && record['repo'] == body['repo']
    return 'tampered' unless record['grant_id'] == id
    return 'unverified' if verification_problem(record['proof'])

    window_problem(record['proof'], body)
  end

  def verification_problem(proof)
    return true unless proof['kind'] == ApprovalConsole::ProofCheck::PASSKEY_KIND

    # The verifier fills in this machine's id, so a receipt for another machine is refused.
    expected = ApprovalConsole::Remote.expected_from_body(proof['body']).except('machine_id')
    # The passkey level checks the local pins against the repository's own
    # approval_pins, so replaced local keys cannot vouch for a hand-made grant.
    ApprovalConsole::ProofCheck.new(level: 'passkey', store: @store, pins: authoritative_pins, now: @now).receipt_problem(proof, expected)
  rescue StandardError
    true # a malformed proof is unverified, never an abort of the scan
  end

  # The default branch's approval_pins for this project, resolved once and
  # fail-closed: an unreadable policy leaves no pins, so nothing verifies.
  def authoritative_pins
    return @pins unless @pins == :authoritative

    return @authoritative_pins if defined?(@authoritative_pins) # a failed lookup is cached too

    @authoritative_pins = begin
      ApprovalConsole::Recorder.authority_for(CfProjectIdentity.for(@project).root).policy&.approval_pins
    rescue StandardError
      nil
    end
  end

  def window_problem(proof, body)
    accepted = ApprovalConsole::ProofCheck.accepted_at(proof)
    return 'unverified' unless accepted

    skew = ApprovalConsole::ProofCheck::MAX_SKEW
    created = Time.iso8601(body['created_at'])
    request_end = Time.iso8601(body['expires_at'])
    return 'expired' unless @now < Time.iso8601(body['grant_expires_at'])
    return 'receipt-outside-window' if accepted > @now + skew || accepted < created - skew || accepted > request_end + skew

    nil
  end

  def accepted(record) = ApprovalConsole::ProofCheck.accepted_at(record['proof'])
end

# CLI: `pulse_grants.rb list [--project DIR]` prints the active grants as JSON.
# Read-only; there is deliberately no verb that creates or extends a grant.
class PulseGrantsCLI
  def self.run(argv, out: $stdout)
    opts = argv.drop(1).each_slice(2).to_h { |flag, value| [ flag.delete_prefix('--'), value ] }
    return usage(out) unless argv.first == 'list'

    grants = PulseGrants.new(project: opts['project'] || Dir.pwd)
    out.puts(JSON.generate('grants' => grants.active.map { |g| { 'id' => g.id, 'scope' => g.scope_list, 'expires_at' => g.expires_at.utc.iso8601 } },
                           'rejected' => grants.rejected.transform_values { |entry| entry[:reason] }))
    0
  end

  def self.usage(out)
    out.puts(JSON.generate('error' => 'usage: pulse_grants.rb list [--project DIR]'))
    2
  end
end

exit(PulseGrantsCLI.run(ARGV)) if __FILE__ == $PROGRAM_NAME
