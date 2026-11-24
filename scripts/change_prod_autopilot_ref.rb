# frozen_string_literal: true

require_relative 'approval_console/canonical'
require_relative 'change_autopilot_store'
require_relative 'change_prod_envelope'
require_relative 'change_prod_gate'
require_relative 'change_prod_store'

# Publishes an autopilot to the prod runner, from Ruby only (the hooks deny raw
# git writes to the runner's refs). The receipt is passkey signed and the
# runner verifies it offline against pinned credentials, so publishing it is
# not a forgery path; the end marker only narrows.
#
#   publish      refs/cf-prod/autopilots/<id>       when the scope has `prod` and
#                                                   the repo declares runners.prod
#   publish_end  refs/cf-prod/autopilot-ends/<id>   written by `change_autopilot.rb end`
#
# Both are best effort for the local autopilot (its own receipt and tombstone
# are the source of truth for the gates) and return a note for the caller to
# print: a publish that failed means the runner will not honor the autopilot;
# an end that failed means the runner still would, until its signed end.
module ChangeProdAutopilotRef
  Outcome = Struct.new(:ok, :note, keyword_init: true) do
    def ok? = ok
  end

  module_function

  def publisher(root) = ->(proof, expected) { publish(root: root, proof: proof, expected: expected) }

  def prod_runner?(root)
    config = ChangeProdEnvelope.load_config(File.join(root, 'CHANGE.md'))
    config.dig('change_config', 'runners', 'prod').is_a?(Hash)
  rescue ChangeProdEnvelope::Invalid
    false
  end

  # A note string, or nil when there is nothing to publish.
  def publish(root:, proof:, expected:, store: nil, receipts: ChangeAutopilotStore.new)
    return nil unless Array(expected['scope_list']).include?('prod') && prod_runner?(root)

    id = ApprovalConsole::Canonical.body_sha256(proof['body'])
    # Recorded first: if the push half-fails, `end` still tells the runner.
    receipts.mark_published(id, root: root)
    store ||= ChangeProdStore.new(root)
    store.create('autopilots', id, { 'protocol' => ChangeProdGate::AUTOPILOT_PROTOCOL, 'autopilot_id' => id, 'proof' => proof })
    "published to the prod runner (refs/cf-prod/autopilots/#{id[0, 12]})"
  rescue ChangeProdStore::Exists => e
    # A failed push removes the local ref, so a ref still here means it was published before.
    store.exists?('autopilots', id) ? 'already published to the prod runner' : not_published(e)
  rescue StandardError => e
    not_published(e)
  end

  # Outcome. ok means the runner can no longer honor the autopilot, or it was
  # never published there. `published` is the persisted publish record, never
  # the current CHANGE.md: with a record the marker is always written and a
  # failure is never ok; with none there is nothing at the runner to end.
  def publish_end(root:, id:, by:, reason:, published:, store: nil)
    return Outcome.new(ok: true) unless published

    store ||= ChangeProdStore.new(root)
    store.create('autopilot-ends', id, { 'ended_by' => by.to_s, 'reason' => reason.to_s, 'ended_at' => Time.now.utc.iso8601 })
    Outcome.new(ok: true, note: "told the prod runner (refs/cf-prod/autopilot-ends/#{id[0, 12]})")
  rescue ChangeProdStore::Exists => e
    return Outcome.new(ok: true, note: 'the prod runner was already told') if store.exists?('autopilot-ends', id)

    not_told(e)
  rescue StandardError => e
    not_told(e)
  end

  def not_published(error) = "NOT published to the prod runner, so it will not cover prod there: #{error.message}"

  def not_told(error)
    Outcome.new(ok: false, note: "the prod runner was NOT told and honors the autopilot until its signed end: #{error.message}")
  end
end
