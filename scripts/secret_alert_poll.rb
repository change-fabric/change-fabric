#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative 'hook_event'
require_relative 'contributors_team'
require_relative 'ed25519_signing'
require_relative 'hook_http'

# SessionStart hook (Capability C delivery, plan section 9.6): a Lambda cannot
# push into a live session, so at session start we sign a lightweight poll and
# ask the backend whether a secret was found in one of this contributor's past
# transcripts. On a finding, inject an AskUserQuestion directive and stash the
# finding so the PostToolUse ack hook (secret_ack.rb) can report the choice.
# Fail silent: any error, timeout, missing key, or no-finding response injects
# nothing. Off unless PST_SECRET_ALERTS=1.
class SecretAlertPoll
  EVENT = 'SessionStart'
  ENDPOINT = 'https://api.changefabric.org/notifications'
  TIMEOUT = 2

  OPTIONS = [
    "Accept the risk. It's not really a secret",
    'Plan to rotate it later. This is a sandbox secret for an initial build-out.',
    'Rotate it immediately and notify stakeholders.'
  ].freeze

  def initialize(event)
    @event = event
  end

  def emit(io = $stdout)
    return unless ENV['PST_SECRET_ALERTS'] == '1'

    identity = ContributorsTeam.new(cwd).identity
    return unless identity

    payload = signed_payload(identity)
    return unless payload

    finding = poll(payload)
    return unless finding?(finding)

    stash(identity, finding)
    io.puts(JSON.generate(context(finding)))
  rescue Exception # rubocop:disable Lint/RescueException
    # Fail silent (covers LoadError from a missing ed25519 gem too); inject nothing.
    nil
  end

  private

  def cwd = (@event['cwd'] || Dir.pwd).to_s

  # 4 fields, in the notifications-poll order: team_id, contributor_id, ts, nonce.
  def signed_payload(identity)
    Ed25519Signing.signed_payload(
      {
        'team_id' => identity.team_id,
        'contributor_id' => identity.contributor_id,
        'ts' => Ed25519Signing.timestamp,
        'nonce' => Ed25519Signing.nonce
      },
      identity.team_id
    )
  end

  def poll(payload) = HookHttp.post_json(ENDPOINT, payload, timeout: TIMEOUT)

  def finding?(finding)
    finding.is_a?(Hash) && finding['status'] != 'none' && !finding['finding_id'].to_s.empty?
  end

  # Stash {finding_id, team_id, contributor_id} for secret_ack.rb, mirroring
  # merge_mode_store's ~/.claude/pst/sessions/<session_id>/... path convention.
  def stash(identity, finding)
    session_id = @event['session_id'].to_s
    return if session_id.empty?

    path = File.join(Dir.home, '.claude', 'pst', 'sessions', session_id, 'pending-secret-ack.json')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(
                       'finding_id' => finding['finding_id'].to_s,
                       'team_id' => identity.team_id,
                       'contributor_id' => identity.contributor_id
                     ))
  end

  def context(finding)
    { hookSpecificOutput: { hookEventName: EVENT, additionalContext: directive(finding) } }
  end

  def directive(finding)
    <<~TEXT.strip
      [pst] Before responding to anything else, call the AskUserQuestion tool about a possible leaked secret found in an earlier session's transcript.

      Detector: #{finding['rule_id']}
      Masked preview: #{finding['masked_preview']}
      Origin session: #{finding['session_id']}
      Location: #{finding['match_location']}

      Question: "A possible secret (#{finding['rule_id']}) was detected in a transcript. How do you want to handle it?"
      Header: "Secret alert"
      Options:
        1. "#{OPTIONS[0]}"
        2. "#{OPTIONS[1]}"
        3. "#{OPTIONS[2]}"

      After the user answers, acknowledge their choice in one line.
    TEXT
  end
end

SecretAlertPoll.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
