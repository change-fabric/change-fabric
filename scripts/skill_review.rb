#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'skill_registry'
require_relative 'review_queue'
require_relative 'review_prompt'

# Stop hook: when the turn ends, if review-enabled files changed this session and
# have no review verdict yet, block and hand the agent the review prompt. This is
# the catch-all that also covers Local-only sessions, which never push and so
# never reach the review_gate. It reads the queue without draining; the queue is
# cleared only by review_ack (run after a review returns), the same completion
# signal the gate uses, so the two share one verdict and neither clears the other
# prematurely. stop_hook_active stops an intra-turn loop; the round cap bounds
# re-blocking across turns if a batch is never acked.
class SkillReview
  EVENT = 'Stop'

  def initialize(event, skills: nil)
    @event = event
    @skills = skills
  end

  def emit(io = $stdout)
    return if @event['stop_hook_active']

    queue = ReviewQueue.new(@event['session_id'])
    return if queue.empty?

    io.puts(JSON.generate(response(queue)))
  end

  private

  def registry = @skills ||= SkillRegistry.load

  # Block to drive a review, unless the round cap is reached: then surface a
  # loud, non-blocking notice rather than silently swallowing further reviews.
  def response(queue)
    return { systemMessage: ReviewPrompt.cap_notice(queue.pending.size) } if queue.capped?

    queue.bump_round
    { decision: 'block', reason: ReviewPrompt.build(queue.pending, registry, @event['session_id']) }
  end
end

SkillReview.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
