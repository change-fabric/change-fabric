#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'merge_mode_store'
require_relative 'merge_mode_slug'
require_relative 'away_store'

# SessionStart hook: states the current merge mode (falling back to
# local-only when nothing is persisted) and, when it is on, states away mode.
# It never asks.
class MergeModeHook
  EVENT = 'SessionStart'

  def initialize(event)
    @event = event
  end

  def emit(io = $stdout)
    io.puts(JSON.generate(payload))
  end

  private

  def payload
    { hookSpecificOutput: { hookEventName: EVENT, additionalContext: directive } }
  end

  def directive
    lines = [restate(mode)]
    lines << away_statement if AwayStore.new(@event['session_id']).away?
    lines.join("\n")
  end

  def mode
    MergeModeSlug.of(MergeModeStore.new(@event['session_id']).mode) || MergeModeSlug::FALLBACK
  end

  def restate(mode)
    "[cf] Merge mode for this session is #{mode}. Honor it per the /cf rules; " \
      'run /cf:local-only, /cf:merge-ready, /cf:admin-bypass, /cf:yolo, or /cf to change it.'
  end

  def away_statement
    '[cf] Away mode is active for this session. Do not ask questions; take the recommended/safe default and continue. Run /cf:active to end away mode.'
  end
end

MergeModeHook.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
