#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'

# Reads and writes the away flag for a session, keyed by session id under
# ~/.claude/cf/sessions. Per-session by decision: the human may run several
# sessions and silence only one. A blank session id is non-persistable.
class AwayStore
  AWAY = 'away'
  ACTIVE = 'active'

  def initialize(session_id)
    @session_id = session_id.to_s
  end

  def away? = state == AWAY

  def state
    return ACTIVE unless persistable? && File.exist?(path)

    File.read(path).strip == AWAY ? AWAY : ACTIVE
  end

  def write(state)
    return unless persistable?

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{state == AWAY ? AWAY : ACTIVE}\n")
  end

  private

  def persistable? = !@session_id.empty?

  def path = File.join(Dir.home, '.claude', 'cf', 'sessions', @session_id, 'away')
end
