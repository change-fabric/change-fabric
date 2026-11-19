#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'skill_registry'
require_relative 'review_queue'
require_relative 'review_key'
require_relative 'review_prompt'
require_relative 'review_scope'
require_relative 'skill_compiler'

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
  # rewrite: false leaves the REVIEWER placeholder for cf_host_hook, which
  # rewrites it for the host it serves; the native Claude hook rewrites here.
  def initialize(event, skills: nil, rewrite: true)
    @event = event
    @skills = skills
    @rewrite = rewrite
  end

  def emit(io = $stdout)
    return if @event['stop_hook_active']

    keys = queue_keys
    return if keys.empty?

    queues = keys.map { |key| ReviewQueue.new(key) }
    pending = in_scope(ReviewScope.covered(queues.flat_map(&:pending), registry))
    return if pending.empty?

    io.puts(JSON.generate(response(queues.first, pending, keys)))
  end

  private

  def registry = @skills ||= SkillRegistry.load

  def subagent_stop? = @event['hook_event_name'] == 'SubagentStop'

  # A SubagentStop without an agent_id has no queue of its own to review. The
  # coordinator reads the key its own edits enqueue under (session@slug when
  # it runs inside a worktree) plus the bare session key.
  def queue_keys
    session = @event['session_id'].to_s
    unless subagent_stop?
      return [] if session.empty?

      return [ ReviewKey.for(@event), session ].uniq
    end

    agent = @event['agent_id'].to_s
    agent.empty? ? [] : [ "#{session}:#{agent}" ]
  end

  def own_root = @own_root ||= ReviewKey.toplevel(@event['cwd']).to_s

  # The coordinator sees only its own tree, minus agent worktrees nested
  # below it. An unresolvable cwd keeps every non-worktree row, so a missing
  # cwd never silently drops the coordinator's own work.
  def in_scope(rows)
    return rows if subagent_stop?

    rows.select { |row| ReviewKey.own_tree?(row[:path], own_root) }
  end

  # Block to drive a review, unless the round cap is reached: then surface a
  # loud, non-blocking notice rather than silently swallowing further reviews.
  def response(queue, pending, keys)
    return { systemMessage: ReviewPrompt.cap_notice(pending.size) } if queue.capped?(pending)

    queue.bump_round(pending)
    scope = subagent_stop? ? nil : own_root
    prompt = ReviewPrompt.build(pending, registry, keys, own_tree: scope)
    prompt = SkillCompiler.new(host: 'claude').rewrite_reviewer(prompt) if @rewrite
    { decision: 'block', reason: prompt }
  end
end

if __FILE__ == $PROGRAM_NAME
  event = HookEvent.read
  HookEvent.debug_keys(event, 'skill_review')
  SkillReview.new(event).emit
end
