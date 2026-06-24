#!/usr/bin/env ruby
# frozen_string_literal: true

# Extracts the chosen merge-mode label from an AskUserQuestion tool response,
# matching on the "Merge mode" question header. Returns nil for any shape that
# does not carry a non-empty string answer.
class MergeModeAnswer
  HEADER = 'Merge mode'

  def initialize(tool_response)
    @tool_response = tool_response
  end

  def label
    return nil unless @tool_response.is_a?(Hash)

    question = questions.find { |q| q.is_a?(Hash) && q['header'] == HEADER }
    return nil unless question

    chosen = answers[question['question']]
    chosen if chosen.is_a?(String) && !chosen.empty?
  end

  private

  def questions = Array(@tool_response['questions'])

  def answers
    map = @tool_response['answers']
    map.is_a?(Hash) ? map : {}
  end
end
