#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'away_store'

# UserPromptSubmit hook: re-injects the away directive as context each turn
# while away mode is on. Emits nothing when away is not set.
class AwayRestate
  EVENT = 'UserPromptSubmit'

  def initialize(event)
    @event = event
  end

  def emit(io = $stdout)
    return unless AwayStore.new(@event['session_id']).away?

    io.puts(JSON.generate(payload))
  end

  private

  def payload
    { hookSpecificOutput: { hookEventName: EVENT, additionalContext: context } }
  end

  def context
    '[cf] Away mode active. Do not ask questions; take the recommended/safe default and continue. ' \
      'Run /cf:active to end away mode.'
  end
end

AwayRestate.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
