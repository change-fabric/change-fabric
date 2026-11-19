# frozen_string_literal: true

require_relative 'canonical'
require_relative 'local_store'
require_relative 'verifier'

module ApprovalConsole
  # The gate's view of stored approval proofs. Every proof present is verified
  # offline against the gate's own context; a malformed, invalid or conflicted
  # proof is always a problem. A record with no proof is tolerated only while
  # `change_policy.require_approval_proof` is unset (the compatibility window),
  # and is reported in `warnings`. `local` accepts any valid proof, terminal
  # included; `remote` requires a console receipt.
  class ProofCheck
    LEVELS = %w[local remote].freeze

    attr_reader :warnings

    def initialize(level:, store: LocalStore.new)
      @level = LEVELS.include?(level) ? level : nil
      @store = store
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
    def override_problem(record, repo:, sha:, profile:)
      return missing('override') unless record.key?('proof')

      proof = record['proof']

      expected = { 'type' => 'override', 'repo' => repo, 'sha' => sha, 'profile' => profile, 'reason' => record['reason'] }
      problem = proof_problem(proof, expected)
      problem && "override proof is refused: #{problem}"
    end

    private

    def missing(what)
      return "no approval proof on the #{what} (require_approval_proof: #{@level})" if @level

      @warnings << "unproven #{what}: recorded without a proof"
      nil
    end

    def proof_problem(proof, expected)
      return 'the proof is not an object' unless proof.is_a?(Hash)
      return "marked conflict on sync (#{proof['conflict']})" if proof['conflict']

      machine = @store.machine_id
      return 'this machine has no approval enrollment to verify against' unless machine

      result = verifier.verify(proof, expected: expected.merge('machine_id' => machine), require_receipt: @level == 'remote')
      result.ok? ? nil : result.reason
    end

    def verifier
      pins = @store.pins
      @verifier ||= Verifier.new(rp_id: pins['rp_id'], credentials: pins['credentials'] || {},
                                 receipt_public_key: pins['receipt_public_key'])
    end
  end
end
