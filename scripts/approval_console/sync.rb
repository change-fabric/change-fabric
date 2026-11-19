# frozen_string_literal: true

require_relative 'canonical'
require_relative 'client'
require_relative 'local_store'
require_relative 'remote'
require_relative '../change_approval_store'
require_relative '../change_override_store'

module ApprovalConsole
  # Uploads offline terminal approvals (approval/pending_sync.jsonl) in step
  # order. The console checks each code for its past step and applies the same
  # fenced last_step write as a live approval: an accepted one comes back with
  # a signed receipt, which is attached to the stored record; a step at or
  # below the console's fence (or outside the grace) is a conflict, and the
  # record is marked so it never passes the gate.
  module Sync
    Report = Struct.new(:synced, :conflicts, :unreachable, keyword_init: true)
    TERMINAL_KIND = 'totp-terminal'

    module_function

    def run(store:, client:, records: Records)
      report = Report.new(synced: 0, conflicts: 0, unreachable: false)
      store.unsynced.sort_by { |entry| entry['step'].to_i }.each do |entry|
        case sync_one(store, client, entry, records)
        when :unreachable
          report.unreachable = true
          break
        when :synced then report.synced += 1
        else report.conflicts += 1
        end
      end
      report
    end

    def sync_one(store, client, entry, records)
      body = entry['body']
      return conflict(store, entry, records, 'the queued entry has no body or code') unless body.is_a?(String) && entry['code']

      proof = client.sync(body, entry['step'], entry['code'])['proof']
      problem = Remote.check(proof, body, Remote.expected_from_body(body), store, kind: TERMINAL_KIND)
      return conflict(store, entry, records, "receipt did not verify: #{problem}") if problem

      records.attach(body, proof['receipt'])
      store.settle(entry['body_sha256'], :synced)
      store.observe_step(proof['totp_step'])
      :synced
    rescue Client::Unreachable
      :unreachable
    rescue Client::Refused => e
      return :unreachable if [ 423, 429 ].include?(e.status)

      conflict(store, entry, records, e.code.empty? ? e.message : e.code)
    rescue Canonical::Invalid => e
      conflict(store, entry, records, e.message)
    end

    def conflict(store, entry, records, reason)
      records.mark_conflict(entry['body'], reason) if entry['body'].is_a?(String)
      store.settle(entry['body_sha256'], :conflict, reason: reason)
      :conflict
    end

    # Finds the stored approval or override whose proof carries `body`.
    module Records
      module_function

      def attach(body, receipt) = update(body) { |proof| proof.merge('receipt' => receipt).except('conflict') }

      def mark_conflict(body, reason) = update(body) { |proof| proof.merge('conflict' => reason.to_s) }

      def update(body, &)
        parsed = Canonical.parse(body)
        case parsed['type']
        when 'step' then ChangeApprovalStore.new(parsed['sha']).update_proofs(body, &)
        when 'override' then ChangeOverrideStore.new(parsed['sha'], profile: parsed['profile']).update_proof(body, &)
        end
      rescue Canonical::Invalid
        nil
      end
    end
  end
end
