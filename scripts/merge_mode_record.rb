#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'hook_event'
require_relative 'merge_mode_store'
require_relative 'merge_mode_answer'
require_relative 'away_store'
require_relative 'away_answer'

# PostToolUse hook: persists both axes chosen via /cf's single AskUserQuestion
# call. Merge mode and away mode are asked as two questions in one call, so
# one PostToolUse event carries both answers; this hook records each into its
# own store.
class MergeModeRecord
  def initialize(event)
    @event = event
  end

  def call
    return unless @event['tool_name'] == 'AskUserQuestion'

    record_merge_mode
    record_away_mode
  end

  private

  def record_merge_mode
    label = MergeModeAnswer.new(@event['tool_response']).label
    return unless label

    MergeModeStore.new(@event['session_id']).write(label)
  end

  def record_away_mode
    label = AwayAnswer.new(@event['tool_response']).label
    return unless label

    state = label.to_s.strip.downcase == AwayStore::AWAY ? AwayStore::AWAY : AwayStore::ACTIVE
    AwayStore.new(@event['session_id']).write(state)
  end
end

MergeModeRecord.new(HookEvent.read).call if __FILE__ == $PROGRAM_NAME
