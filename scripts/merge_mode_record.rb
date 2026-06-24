#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'hook_event'
require_relative 'merge_mode_store'
require_relative 'merge_mode_answer'

# PostToolUse hook: persists the merge mode chosen via an AskUserQuestion answer.
class MergeModeRecord
  def initialize(event)
    @event = event
  end

  def call
    return unless @event['tool_name'] == 'AskUserQuestion'

    label = MergeModeAnswer.new(@event['tool_response']).label
    return unless label

    MergeModeStore.new(@event['session_id']).write(label)
  end
end

MergeModeRecord.new(HookEvent.read).call if __FILE__ == $PROGRAM_NAME
