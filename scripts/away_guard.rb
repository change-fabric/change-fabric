#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'away_store'

# PreToolUse hook: denies an AskUserQuestion call made while away mode is on,
# unless one of its questions carries a floor header. The floor exists for
# questions whose default is destructive or where a real secret is at stake
# and no safe default exists.
class AwayGuard
  EVENT = 'PreToolUse'

  # Questions that fire even while away, because their default is destructive
  # or a real secret is at stake and no safe default exists.
  FLOOR = [ 'Remote delete', 'Untracked', 'Secret alert' ].freeze

  def initialize(event)
    @event = event
  end

  def emit(io = $stdout)
    return unless @event['tool_name'] == 'AskUserQuestion'
    return unless AwayStore.new(@event['session_id']).away?
    return if floored?

    io.puts(JSON.generate(deny(headers)))
  end

  private

  def questions
    input = @event['tool_input']
    return [] unless input.is_a?(Hash)

    qs = input['questions']
    qs.is_a?(Array) ? qs : []
  end

  def headers
    questions.filter_map { |q| q['header'] if q.is_a?(Hash) }
  end

  def floored?
    headers.any? { |h| FLOOR.include?(h) }
  end

  def deny(headers)
    {
      hookSpecificOutput: {
        hookEventName: EVENT,
        permissionDecision: 'deny',
        permissionDecisionReason: reason(headers)
      }
    }
  end

  def reason(headers)
    list = headers.empty? ? '(no header set)' : headers.join(', ')
    "[cf] Away mode is active: this AskUserQuestion call (#{list}) is not allowed. " \
      'Take the recommended or safe default and continue; report what was assumed. ' \
      'Run /cf:active to end away mode and resume asking normally.'
  end
end

AwayGuard.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
