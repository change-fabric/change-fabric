#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "merge_mode_store"

class MergeModeAnswer
  HEADER = "Merge mode"

  def initialize(tool_response)
    @tool_response = tool_response
  end

  def label
    return nil unless @tool_response.is_a?(Hash)

    question = questions.find { |q| q.is_a?(Hash) && q["header"] == HEADER }
    return nil unless question

    chosen = answers[question["question"]]
    chosen if chosen.is_a?(String) && !chosen.empty?
  end

  private

  def questions = Array(@tool_response["questions"])

  def answers
    map = @tool_response["answers"]
    map.is_a?(Hash) ? map : {}
  end
end

class MergeModeRecord
  def initialize(event)
    @event = event
  end

  def call
    return unless @event["tool_name"] == "AskUserQuestion"

    label = MergeModeAnswer.new(@event["tool_response"]).label
    return unless label

    MergeModeStore.new(@event["session_id"]).write(label)
  end
end

if __FILE__ == $PROGRAM_NAME
  MergeModeRecord.new(HookEvent.read).call
end
