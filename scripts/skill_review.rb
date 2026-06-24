#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'skill_registry'
require_relative 'review_queue'

# Stop hook: when the turn ends, if review-enabled files changed this session,
# block once and hand the agent a fixed prompt to run a haiku background review.
# Draining the queue (and honoring stop_hook_active) guarantees it fires once
# per batch, never in a loop. The hook authors the prompt; the agent runs the
# review via Claude Code's real background-agent mechanism.
class SkillReview
  EVENT = 'Stop'

  def initialize(event, skills: nil)
    @event = event
    @skills = skills
  end

  def emit(io = $stdout)
    return if @event['stop_hook_active']

    queue = ReviewQueue.new(@event['session_id'])
    entries = queue.drain
    return if entries.empty?

    queue.mark_reviewed(entries)
    io.puts(JSON.generate(response(queue, entries)))
  end

  private

  def registry = @skills ||= SkillRegistry.load

  # Block to drive a review, unless the round cap is reached: then surface a
  # loud, non-blocking notice rather than silently swallowing further reviews.
  def response(queue, entries)
    return { systemMessage: cap_notice(entries) } if queue.capped?

    queue.bump_round
    { decision: 'block', reason: prompt(entries) }
  end

  def cap_notice(entries)
    "[pst review] Round cap (#{ReviewQueue::CAP}) reached; #{entries.size} file(s) " \
      'still changing. Automatic design review is paused for this session; review ' \
      'remaining changes manually or invoke /pst:ruby.'
  end

  def skills_by_name = registry.to_h { |skill| [ skill.name, skill ] }

  def prompt(entries)
    by_name = skills_by_name
    sections = entries.group_by { |entry| entry[:skill] }
                      .map { |name, rows| review_section(by_name[name], name, rows) }
    <<~TEXT.strip
      [pst review] Before you finish: #{entries.size} file(s) changed this session
      under review-enabled skills. Spawn a background review agent now, then finish.

      Use Agent(subagent_type: "general-purpose", model: "haiku", run_in_background: true),
      giving it exactly the task below. Report only concrete violations as
      `path:line - smell -> smallest behavior-preserving fix`; if none, say "clean".
      This is a one-time review of the current batch and will not fire again.

      #{sections.join("\n\n")}
    TEXT
  end

  def review_section(skill, name, rows)
    files = rows.map { |row| "- #{row[:path]}" }.join("\n")
    <<~TEXT.strip
      ## Review against the #{name} skill
      #{taxonomy_note(skill)}
      Files:
      #{files}

      #{name} principles:
      #{skill&.body || '(principles unavailable)'}
    TEXT
  end

  # all_code skills match by extension, which can misfire on data or prose that
  # merely looks like code. Tell the reviewer to judge code-ness first.
  def taxonomy_note(skill)
    return '' unless skill&.all_code?

    "\nFirst confirm each changed file is genuinely code (it may be code embedded " \
      "in another format). Review only real code; mark anything that is not code as clean.\n"
  end
end

SkillReview.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
