#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'skill_registry'
require_relative 'review_queue'
require_relative 'review_key'
require_relative 'review_prompt'
require_relative 'skill_compiler'
require_relative 'review_scope'
require_relative 'guarded_command'
require_relative 'change_autopilot'
require_relative 'review_stage1'

# PreToolUse hook: denies a push or PR when files changed this session lack a
# review verdict, and hands back the review prompt. The verdict must be for
# their current content. This makes design review precede PR creation;
# the Stop hook (skill_review) fires too late, once the PR already exists.
#
# Fail-closed and deterministic: the gate never clears itself. It denies while
# the queue holds unreviewed files and is released only by review_ack (run after
# a review returns), so dispatching the prompt does not unblock - a finished
# review does. The round cap is the escape valve against a wedged batch: the
# identical batch denied CAP times in a row. A changed batch resumes gating on
# its own. Local-only sessions never push, so skill_review still covers them at
# Stop; both read the same queue and the same ack clears both.
#
# Two stages. Stage 1 (review_stage1) is deterministic and runs first: repo
# linters, the glyph check, the CHANGE.md command lane and tests. Any blocking
# result denies with the findings and no model is called. Only on an all-clear
# does stage 2 run: the Sonnet (worker role) judgment review the prompt hands
# back, which an ack releases.
#
# Like merge_mode_guard, this is a loud guardrail keyed on command text, not a
# sandbox: it is bypassable (git -c, env indirection, a non-Bash path).
class ReviewGate
  EVENT = 'PreToolUse'

  # stage1: (root) -> ReviewStage1::Report, injected by tests. The default runs
  # the real checks in the repo the command was issued from; with no known repo
  # root there is nothing to check and stage 1 is skipped.
  def initialize(event, skills: nil, stage1: ->(root) { ReviewStage1.run(root) })
    @event = event
    @skills = skills
    @stage1 = stage1
  end

  def emit(io = $stdout)
    return unless @event['tool_name'] == 'Bash'
    return unless GuardedCommand.push?(command) || GuardedCommand.pr_create?(command)

    report = stage1_report
    return io.puts(JSON.generate(deny(report.to_text))) if report&.blocking?

    by_key = pending_by_key
    pending = by_key.values.flatten
    return if pending.empty?
    # An autopilot naming review allows the push and leaves the queue intact.
    return if autopilot_waives?(pending)

    io.puts(JSON.generate(response(ReviewQueue.new(@event['session_id']), pending, by_key.keys)))
  end

  private

  def autopilot_waives?(pending)
    !ChangeAutopilot.waive!('review', guard: 'review_gate', detail: "#{pending.size} unreviewed file(s)", command: command,
                                      session: @event['session_id']).nil?
  end

  def stage1_report
    root = ReviewScope.repo_root(@event['cwd'].to_s) unless @event['cwd'].to_s.empty?
    root && @stage1.call(root)
  end

  def registry = @skills ||= SkillRegistry.load

  def command
    input = @event['tool_input']
    input.is_a?(Hash) ? input['command'].to_s : ''
  end

  # Until the gate is scoped to the pushed branch diff, it keeps today's reach:
  # every queue this session owns (its own, each agent's, each worktree's), so
  # moving agent edits out of the coordinator key never lets a push through
  # unreviewed. The ack it hands back names exactly the keys holding rows.
  def pending_by_key
    ReviewKey.keys_for_session(@event['session_id'].to_s).to_h do |key|
      [ key, ReviewScope.covered(ReviewQueue.new(key).pending, registry) ]
    end.reject { |_key, rows| rows.empty? }
  end

  def response(queue, pending, keys)
    return { systemMessage: ReviewPrompt.cap_notice(pending.size) } if queue.capped?(pending)

    queue.bump_round(pending)
    deny(SkillCompiler.new(host: 'claude').rewrite_reviewer(ReviewPrompt.stage2(pending, registry, keys), role: 'worker'))
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

if __FILE__ == $PROGRAM_NAME
  event = HookEvent.read
  HookEvent.debug_keys(event, 'review_gate')
  HookEvent.instrument('review_gate', event) { ReviewGate.new(event).emit }
end
