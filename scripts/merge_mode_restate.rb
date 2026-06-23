#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "merge_mode_store"

class MergeModeRestate
  EVENT = "UserPromptSubmit"

  def initialize(event)
    @event = event
  end

  def emit(io = $stdout)
    mode = MergeModeStore.new(@event["session_id"]).mode
    return unless mode

    io.puts(JSON.generate(payload(mode)))
  end

  private

  def payload(mode)
    { hookSpecificOutput: { hookEventName: EVENT, additionalContext: context(mode) } }
  end

  def context(mode)
    "[pst] Active merge mode: #{mode}. Honor it for this turn per the /pst rules."
  end
end

if __FILE__ == $PROGRAM_NAME
  MergeModeRestate.new(HookEvent.read).emit
end
