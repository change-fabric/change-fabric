#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'pathname'
require_relative 'hook_event'
require_relative 'contributors_team'
require_relative 'ed25519_signing'
require_relative 'hook_http'

# PreToolUse hook (Capability B, plan sections 9.2-9.4): before an
# Edit/Write/NotebookEdit inside a registered team repo, ask the backend "is a
# teammate already on this file?" On a collision, deny the edit and inject an
# AskUserQuestion directive. Latency-critical and FAIL OPEN: any error, timeout,
# missing key, or non-collision response prints nothing and exits 0. Presence
# may miss a collision but must never stand between a contributor and their edit.
# Off unless CF_PRESENCE=1.
class PresenceProbe
  EVENT = 'PreToolUse'
  ENDPOINT = 'https://api.changefabric.org/presence'
  EDIT_TOOLS = %w[Edit Write NotebookEdit].freeze
  TIMEOUT = 0.75 # 750ms budget, section 9.3

  OPTIONS = [
    'Stop working on this file and touch base with the other contributor to make sure we are aligned on next steps.',
    "Keep going. We'll deal with the merge conflicts later.",
    'We already talked. Looks good to me.'
  ].freeze

  def initialize(event)
    @event = event
  end

  def emit(io = $stdout)
    return unless ENV['CF_PRESENCE'] == '1'
    return unless EDIT_TOOLS.include?(@event['tool_name'])

    file_path = target_file
    return unless file_path

    team = ContributorsTeam.new(File.dirname(file_path))
    identity = team.identity
    return unless identity

    rel = repo_relative(team.repo_root, file_path)
    return unless rel

    payload = signed_payload(identity, rel)
    return unless payload

    result = probe(payload)
    return unless collision?(result)

    io.puts(JSON.generate(deny(result)))
  rescue Exception # rubocop:disable Lint/RescueException
    # Fail open on anything (covers LoadError from a missing ed25519 gem too).
    nil
  end

  private

  # Edit/Write/NotebookEdit all carry the absolute target as tool_input.file_path.
  # ASSUMPTION worth verifying against the live harness payload shapes.
  def target_file
    input = @event['tool_input']
    return nil unless input.is_a?(Hash)

    path = input['file_path']
    (path.is_a?(String) && !path.empty?) ? path : nil
  end

  # `root` (from `git rev-parse --show-toplevel`) is already symlink-resolved,
  # so file_path must be too or a symlinked ancestor (e.g. macOS's /tmp ->
  # /private/tmp) makes the two paths disagree and relative_path_from walks
  # all the way up to the real filesystem root instead of the repo root. A
  # not-yet-created file (Write, before the file exists) can't be realpath'd
  # directly, so resolve its parent directory and rejoin the basename.
  def repo_relative(root, file_path)
    return nil unless root

    resolved = if File.exist?(file_path)
                 File.realpath(file_path)
    else
                 File.join(File.realpath(File.dirname(file_path)), File.basename(file_path))
    end
    Pathname.new(resolved).relative_path_from(Pathname.new(root)).to_s
  rescue StandardError
    nil
  end

  # 7 fields, in the exact presence-scheme order:
  # team_id, contributor_id, contributor_name, repo_id, file_path, ts, nonce.
  def signed_payload(identity, rel_path)
    Ed25519Signing.signed_payload(
      {
        'team_id' => identity.team_id,
        'contributor_id' => identity.contributor_id,
        'contributor_name' => identity.contributor_name,
        'repo_id' => identity.repo_id.to_s,
        'file_path' => rel_path,
        'ts' => Ed25519Signing.timestamp,
        'nonce' => Ed25519Signing.nonce
      },
      identity.team_id
    )
  end

  def probe(payload) = HookHttp.post_json(ENDPOINT, payload, timeout: TIMEOUT)

  def collision?(result)
    result.is_a?(Hash) && result['status'] == 'collision' && !result['other_name'].to_s.empty?
  end

  def deny(result)
    {
      hookSpecificOutput: {
        hookEventName: EVENT,
        permissionDecision: 'deny',
        permissionDecisionReason: directive(result)
      }
    }
  end

  def directive(result)
    other = result['other_name'].to_s
    detected_at = result['detected_at'].to_s
    <<~TEXT.strip
      [cf] Live-presence collision: #{other} is already editing this file (detected at #{detected_at}). Before responding to anything else, call the AskUserQuestion tool.

      Question: "#{other} is already working in this file. How do you want to proceed?"
      Header: "File collision"
      Options:
        1. "#{OPTIONS[0]}"
        2. "#{OPTIONS[1]}"
        3. "#{OPTIONS[2]}"

      After the user answers, honor their choice before making any edit to this file.
    TEXT
  end
end

PresenceProbe.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
