#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'merge_mode_store'

# UserPromptSubmit hook: re-injects the active merge mode as context each turn.
class MergeModeRestate
  EVENT = 'UserPromptSubmit'

  def initialize(event)
    @event = event
  end

  def emit(io = $stdout)
    mode = MergeModeStore.new(@event['session_id']).mode
    return unless mode

    io.puts(JSON.generate(payload(mode)))
  end

  private

  def payload(mode)
    { hookSpecificOutput: { hookEventName: EVENT, additionalContext: context(mode) } }
  end

  def context(mode)
    "[cf] Active merge mode: #{mode}. Honor it for this turn per the /cf rules."
  end
end

MergeModeRestate.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
