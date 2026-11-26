# frozen_string_literal: true

require_relative '../leased_inbox'

module Triage
  # The triage item kinds on the shared leased inbox. Each builder derives the
  # stable dedup key from kind + unit id + finding, so a tick that sees the
  # same problem again upserts the one item instead of adding another.
  module InboxItems
    KINDS = %w[triage_decision triage_escalation ctx_ambiguous host_stale limited].freeze

    def self.upsert(inbox, kind:, unit:, finding:, title:, body: '', data: {})
      raise ArgumentError, "unknown triage kind #{kind}" unless KINDS.include?(kind)

      inbox.upsert(kind: kind, key: LeasedInbox.dedup_key(kind, unit, finding),
                   title: title, body: body, data: data.merge('unit' => unit, 'finding' => finding))
    end

    # A later tick that no longer sees the finding supersedes its item.
    def self.clear(inbox, kind:, unit:, finding:, reason: 'finding gone')
      key = LeasedInbox.dedup_key(kind, unit, finding)
      inbox.supersede(key, reason: reason) if inbox.fetch(key)
    end
  end
end
