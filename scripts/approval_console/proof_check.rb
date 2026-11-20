# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'canonical'
require_relative 'local_store'
require_relative 'verifier'

module ApprovalConsole
  # The gate's view of stored approval proofs. Every proof present is verified
  # offline against the gate's own context; a malformed, invalid or conflicted
  # proof is always a problem. A record with no proof is tolerated only while
  # `change_policy.require_approval_proof` is unset (the compatibility window),
  # and is reported in `warnings`. `local` accepts any valid proof, terminal
  # included; `remote` requires a console receipt; `passkey` (0.26.0) requires
  # a console receipt for a phone passkey approval (kind webauthn+totp, channel
  # console), checks the local pins against the authoritative `pins`
  # (change_policy.approval_pins on the base or default branch), and refuses an
  # override whose receipt is 24h old or older when it is used.
  class ProofCheck
    LEVELS = %w[local remote passkey].freeze
    PASSKEY_KIND = 'webauthn+totp'
    MAX_AGE = 86_400
    MAX_SKEW = 300
    MIN_REASON = 20

    attr_reader :warnings

    # The receipt's signed accepted_at, or nil when the proof has none that parses.
    def self.accepted_at(proof)
      payload = proof.is_a?(Hash) ? proof.dig('receipt', 'payload') : nil
      payload.is_a?(String) ? Canonical.parse_time(JSON.parse(payload)['accepted_at']) : nil
    rescue JSON::ParserError, TypeError, ArgumentError
      nil
    end

    # Whether the proof's signed receipt accepted_at is under `max_age` seconds
    # old at `at` and not more than five minutes in the future. `max_age` is
    # configurable downward only: anything above 24h is clamped to 24h. Used
    # at record time for every receipt and at use for override, carve-out and
    # release receipts; step approvals never expire.
    def self.fresh?(proof, at:, max_age: MAX_AGE)
      accepted = accepted_at(proof) or return false
      age = at - accepted
      age < [ max_age.to_i, MAX_AGE ].min && age >= -MAX_SKEW
    end

    # `pins` is the authoritative { 'receipt_key_fingerprint', 'rp_id' }; the
    # passkey level refuses every proof without them. `now` is when the proof
    # is used, for the override freshness check.
    def initialize(level:, store: LocalStore.new, pins: nil, now: Time.now)
      @level = LEVELS.include?(level) ? level : nil
      @store = store
      @pins = pins
      @now = now
      @warnings = []
    end

    # nil, or the first problem among the step approvals recorded for `sha`.
    # Entries that share one proof body were approved together, so the signed
    # item set must equal exactly those entries.
    def approvals_problem(entries, repo:, sha:)
      malformed = entries.find { |entry| entry.key?('proof') && !(entry['proof'].is_a?(Hash) && entry['proof']['body'].is_a?(String)) }
      return "approval proof for #{malformed['step']} is refused: the proof is malformed" if malformed

      entries.group_by { |entry| entry.dig('proof', 'body') }.each do |body, group|
        steps = group.map { |entry| entry['step'] }.join(', ')
        if body.nil?
          problem = missing("step approval for #{steps}")
          return problem if problem

          next
        end
        items = group.map { |entry| { 'step' => entry['step'].to_s, 'digest' => entry['digest'].to_s.delete_prefix('sha256:') } }
        expected = { 'type' => 'step', 'repo' => repo, 'sha' => sha, 'profile' => nil, 'items' => items }
        problem = proof_problem(group.first['proof'], expected)
        return "approval proof for #{steps} is refused: #{problem}" if problem
      end
      nil
    end

    # nil, or why the override record's proof does not stand.
    def override_problem(record, repo:, sha:, profile:, scope: nil)
      return missing('override') unless record.key?('proof')

      proof = record['proof']

      expected = { 'type' => 'override', 'repo' => repo, 'sha' => sha, 'profile' => profile, 'reason' => record['reason'] }
      expected['scope'] = scope if scope
      problem = short_reason(record['reason']) || proof_problem(proof, expected) || stale_at_use(proof)
      problem && "override proof is refused: #{problem}"
    end

    # nil, or why `proof` does not verify against `expected` (the full signed
    # context, machine_id aside) at this check's level. The Recorder's entry.
    def receipt_problem(proof, expected) = proof_problem(proof, expected)

    private

    def missing(what)
      return "no approval proof on the #{what} (require_approval_proof: #{@level})" if @level

      @warnings << "unproven #{what}: recorded without a proof"
      nil
    end

    def proof_problem(proof, expected)
      return 'the proof is not an object' unless proof.is_a?(Hash)
      return "marked conflict on sync (#{proof['conflict']})" if proof['conflict']
      return wrong_kind(proof['kind']) if passkey? && proof['kind'] != PASSKEY_KIND

      machine = @store.machine_id
      return 'this machine has no approval enrollment to verify against' unless machine

      result = verifier.verify(proof, expected: expected.merge('machine_id' => machine), require_receipt: %w[remote passkey].include?(@level))
      result.ok? ? nil : result.reason
    rescue LocalStore::PinMismatch => e
      e.message
    end

    def wrong_kind(kind) = "a #{kind.inspect} proof is not a phone passkey approval (require_approval_proof: passkey)"

    def short_reason(reason)
      return nil unless passkey? && reason.to_s.strip.length < MIN_REASON

      "the override reason is under #{MIN_REASON} characters"
    end

    def stale_at_use(proof)
      return nil unless passkey?
      return nil if self.class.fresh?(proof, at: @now)

      'the receipt is 24h old or older, or dated in the future; request a new approval'
    end

    def passkey? = @level == 'passkey'

    def verifier
      @verifier ||= build_verifier
    end

    def build_verifier
      raise LocalStore::PinMismatch, 'the authoritative policy has no approval_pins (require_approval_proof: passkey)' if passkey? && !complete_pins?

      pins = @pins ? @store.pins(expect: @pins) : @store.pins
      Verifier.new(rp_id: pins['rp_id'], credentials: pins['credentials'] || {},
                   receipt_public_key: pins['receipt_public_key'])
    end

    def complete_pins? = @pins.is_a?(Hash) && !@pins['receipt_key_fingerprint'].to_s.empty? && !@pins['rp_id'].to_s.empty?
  end
end
