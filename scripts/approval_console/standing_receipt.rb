# frozen_string_literal: true

require 'time'
require_relative 'canonical'
require_relative 'proof_check'
require_relative 'recorder'
require_relative 'remote'
require_relative '../cf_project_identity'

module ApprovalConsole
  # The checks a standing receipt (a pulse grant or an autopilot) must pass on
  # every read, shared by PulseGrants and ChangeAutopilot. All fail closed:
  #   - the proof is a console receipt of kind webauthn+totp for exactly its
  #     signed body, verified at the passkey level against the repository's
  #     authoritative approval_pins (unreadable policy means no pins, so
  #     nothing verifies) and for this machine;
  #   - now is before the signed end (`expiry_field`), with no skew allowance;
  #   - the receipt was accepted inside the request's own window, give or take
  #     ProofCheck::MAX_SKEW, and not in the future.
  class StandingReceipt
    def initialize(project:, store:, now:, pins: :authoritative)
      @project = project
      @store = store
      @now = now
      @pins = pins
    end

    # A record's parsed body when it is a canonical body of `type`, else nil.
    def self.body_of(record, type)
      proof = record.is_a?(Hash) ? record['proof'] : nil
      text = proof.is_a?(Hash) ? proof['body'] : nil
      return nil unless text.is_a?(String)

      body = Canonical.parse(text)
      body if body['type'] == type
    rescue Canonical::Invalid
      nil
    end

    # Truthy when the proof does not verify (any error counts as unverified).
    def verification_problem(proof)
      return true unless proof['kind'] == ProofCheck::PASSKEY_KIND

      # The verifier fills in this machine's id, so a receipt for another machine is refused.
      expected = Remote.expected_from_body(proof['body']).except('machine_id')
      ProofCheck.new(level: 'passkey', store: @store, pins: authoritative_pins, now: @now).receipt_problem(proof, expected)
    rescue StandardError
      true
    end

    # 'expired', 'receipt-outside-window', 'unverified' or nil.
    def time_problem(proof, body, expiry_field)
      accepted = ProofCheck.accepted_at(proof)
      return 'unverified' unless accepted

      skew = ProofCheck::MAX_SKEW
      created = Time.iso8601(body['created_at'])
      request_end = Time.iso8601(body['expires_at'])
      return 'expired' unless @now < Time.iso8601(body[expiry_field])
      return 'receipt-outside-window' if accepted > @now + skew || accepted < created - skew || accepted > request_end + skew

      nil
    end

    # The default branch's approval_pins for this project, resolved once and
    # fail-closed: an unreadable policy leaves no pins, so nothing verifies.
    def authoritative_pins
      return @pins unless @pins == :authoritative
      return @authoritative_pins if defined?(@authoritative_pins)

      @authoritative_pins = begin
        Recorder.authority_for(CfProjectIdentity.for(@project).root).policy&.approval_pins
      rescue StandardError
        nil
      end
    end
  end
end
