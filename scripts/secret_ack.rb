#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative 'hook_event'
require_relative 'ed25519_signing'
require_relative 'hook_http'

# PostToolUse hook (Capability C ack, plan section 9.7): when the user answers an
# AskUserQuestion and a pending secret-alert stash exists for this session, match
# their answer to one of the three verbatim secret-alert options, sign a 6-field
# ack, POST it, and delete the stash. Fail silent: any error still deletes the
# stash so a failed ack never re-prompts on a later PostToolUse (an unreported
# ack just leaves the finding delivered, still auditable, section 10). Does
# nothing unless the answered question is the secret-alert one.
class SecretAck
  EVENT = 'PostToolUse'
  ENDPOINT = 'https://api.changefabric.org/notifications/ack'
  TIMEOUT = 2

  # The three verbatim secret-alert options, in order, mapping to chosen_option
  # "1"/"2"/"3". Must stay byte-identical to secret_alert_poll.rb's OPTIONS.
  OPTIONS = [
    "Accept the risk. It's not really a secret",
    'Plan to rotate it later. This is a sandbox secret for an initial build-out.',
    'Rotate it immediately and notify stakeholders.'
  ].freeze

  def initialize(event)
    @event = event
  end

  def run
    return unless @event['tool_name'] == 'AskUserQuestion'

    stash = read_stash
    return unless stash

    chosen = chosen_option
    # The stash exists but this AskUserQuestion answered something unrelated:
    # leave the stash alone and do nothing, don't guess.
    return unless chosen

    ack(stash, chosen)
    delete_stash
  rescue Exception # rubocop:disable Lint/RescueException
    # Fail silent (covers LoadError from a missing ed25519 gem too).
    nil
  end

  private

  def stash_path
    session_id = @event['session_id'].to_s
    return nil if session_id.empty?

    File.join(Dir.home, '.claude', 'cf', 'sessions', session_id, 'pending-secret-ack.json')
  end

  def read_stash
    path = stash_path
    return nil unless path && File.exist?(path)

    data = JSON.parse(File.read(path))
    data.is_a?(Hash) ? data : nil
  rescue StandardError
    nil
  end

  def delete_stash
    path = stash_path
    FileUtils.rm_f(path) if path
  rescue StandardError
    nil
  end

  # Match the user's answer against the three verbatim option strings. The
  # AskUserQuestion PostToolUse response shape can vary, so search its whole
  # serialized form for a verbatim option rather than assuming a field path.
  # ASSUMPTION worth verifying against the live harness tool_response shape.
  def chosen_option
    blob = JSON.generate(@event['tool_response'])
    index = OPTIONS.index { |option| blob.include?(option) }
    index ? (index + 1).to_s : nil
  rescue StandardError
    nil
  end

  # 6 fields, in the notifications-ack order:
  # team_id, contributor_id, ts, nonce, finding_id, chosen_option.
  def ack(stash, chosen)
    team_id = stash['team_id'].to_s
    payload = Ed25519Signing.signed_payload(
      {
        'team_id' => team_id,
        'contributor_id' => stash['contributor_id'].to_s,
        'ts' => Ed25519Signing.timestamp,
        'nonce' => Ed25519Signing.nonce,
        'finding_id' => stash['finding_id'].to_s,
        'chosen_option' => chosen
      },
      team_id
    )
    return unless payload

    post(payload)
  end

  # Response ignored; the stash is deleted regardless (section 10).
  def post(payload) = HookHttp.post_json(ENDPOINT, payload, timeout: TIMEOUT)
end

SecretAck.new(HookEvent.read).run if __FILE__ == $PROGRAM_NAME
