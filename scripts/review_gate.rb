#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'skill_registry'
require_relative 'review_queue'
require_relative 'review_prompt'
require_relative 'guarded_command'

# PreToolUse hook: when the agent is about to push or open a PR and files changed
# this session have no review verdict for their current content, deny the command
# and hand back the review prompt. This makes design review precede PR creation;
# the Stop hook (skill_review) fires too late, once the PR already exists.
#
# Fail-closed and deterministic: the gate never clears itself. It denies while
# the queue holds unreviewed files and is released only by review_ack (run after
# a review returns), so dispatching the prompt does not unblock - a finished
# review does. The round cap is the escape valve against a wedged batch. Local
# -only sessions never push, so skill_review still covers them at Stop; both read
# the same queue and the same ack clears both.
#
# Like merge_mode_guard, this is a loud guardrail keyed on command text, not a
# sandbox: it is bypassable (git -c, env indirection, a non-Bash path).
class ReviewGate
  EVENT = 'PreToolUse'

  PR_CREATE = /\bgh\b[^&|;]*\bpr\b[^&|;]*\bcreate\b/
  TRIGGER = Regexp.union(GuardedCommand::PUSH, PR_CREATE)

  def initialize(event, skills: nil)
    @event = event
    @skills = skills
  end

  def emit(io = $stdout)
    return unless @event['tool_name'] == 'Bash'
    return unless command.match?(TRIGGER)

    queue = ReviewQueue.new(@event['session_id'])
    return if queue.empty?

    io.puts(JSON.generate(response(queue)))
  end

  private

  def registry = @skills ||= SkillRegistry.load

  def command
    input = @event['tool_input']
    input.is_a?(Hash) ? input['command'].to_s : ''
  end

  def response(queue)
    return { systemMessage: ReviewPrompt.cap_notice(queue.pending.size) } if queue.capped?

    queue.bump_round
    deny(ReviewPrompt.build(queue.pending, registry, @event['session_id']))
  end

  def deny(reason)
    {
      hookSpecificOutput: {
        hookEventName: EVENT,
        permissionDecision: 'deny',
        permissionDecisionReason: reason
      }
    }
  end
end

ReviewGate.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
