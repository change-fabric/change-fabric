#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'skill_registry'
require_relative 'review_queue'
require_relative 'review_key'
require_relative 'review_prompt'
require_relative 'review_scope'

# Stop hook: when the turn ends, block with the review prompt if review-enabled
# files changed without a review verdict. This is the catch-all that also covers
# Local-only sessions, which never push and so never reach the review_gate. It
# reads the queue without draining; the queue is cleared only by review_ack (run
# after a review returns), the same completion signal the gate uses.
#
# Scope: a Stop reviews only the coordinator's own key, and only rows under its
# own working tree. Agent worktrees and other agents' edits stay queued, unshown;
# the agent's own scope or the push gate owns them. A SubagentStop (when wired)
# reviews the whole of that agent's key. stop_hook_active stops an intra-turn
# loop; the round cap bounds re-blocking across turns if the identical batch is
# denied CAP times in a row. A changed batch resumes blocking on its own.
class SkillReview
  def initialize(event, skills: nil)
    @event = event
    @skills = skills
  end

  def emit(io = $stdout)
    return if @event['stop_hook_active']

    key = queue_key
    return unless key

    queue = ReviewQueue.new(key)
    pending = in_scope(ReviewScope.covered(queue.pending, registry))
    return if pending.empty?

    io.puts(JSON.generate(response(queue, pending, key)))
  end

  private

  def registry = @skills ||= SkillRegistry.load

  def subagent_stop? = @event['hook_event_name'] == 'SubagentStop'

  # A SubagentStop without an agent_id has no queue of its own to review.
  def queue_key
    return @event['session_id'].to_s unless subagent_stop?

    agent = @event['agent_id'].to_s
    agent.empty? ? nil : "#{@event['session_id']}:#{agent}"
  end

  # The coordinator sees only its own tree. An unresolvable cwd keeps every
  # non-worktree row, so a missing cwd never silently drops the coordinator's
  # own work.
  def in_scope(rows)
    return rows if subagent_stop?

    root = ReviewKey.toplevel(@event['cwd'])
    rows.reject { |row| ReviewKey.agent_tree?(row[:path]) }
        .select { |row| root.nil? || row[:path].to_s.start_with?("#{root}/") }
  end

  # Block to drive a review, unless the round cap is reached: then surface a
  # loud, non-blocking notice rather than silently swallowing further reviews.
  def response(queue, pending, key)
    return { systemMessage: ReviewPrompt.cap_notice(pending.size) } if queue.capped?(pending)

    queue.bump_round(pending)
    { decision: 'block', reason: ReviewPrompt.build(pending, registry, key) }
  end
end

if __FILE__ == $PROGRAM_NAME
  event = HookEvent.read
  HookEvent.debug_keys(event, 'skill_review')
  SkillReview.new(event).emit
end
