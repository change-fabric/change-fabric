#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'

# Parse a hook event from stdin. Hooks fire on every event, so a bad or
# unexpected payload must fail silent (empty event), never crash the session.
module HookEvent
  def self.read(io = $stdin)
    raw = io.read.to_s
    return {} if raw.empty?

    parsed = JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  # Opt-in payload shape capture (CF_HOOK_DEBUG_KEYS=1): one line per event
  # naming the hook, the event, the sorted top-level keys and whether agent_id
  # is present. Key names only, never values, so nothing sensitive is logged.
  def self.debug_keys(event, hook_name)
    return unless ENV['CF_HOOK_DEBUG_KEYS'] == '1' && event.is_a?(Hash)

    path = File.join(Dir.home, '.claude', 'cf', 'logs', 'hook-keys.log')
    FileUtils.mkdir_p(File.dirname(path))
    keys = event.keys.map(&:to_s).sort.join(',')
    agent = !event['agent_id'].to_s.empty?
    File.write(path, "#{hook_name}\t#{event['hook_event_name']}\t#{keys}\tagent_id present: #{agent}\n", mode: 'a')
  rescue StandardError
    nil
  end
end
