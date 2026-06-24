#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'digest'
require_relative 'hook_event'
require_relative 'skill_registry'
require_relative 'skill_store'
require_relative 'review_queue'

# PostToolUse hook: after a file edit, surfaces every auto-skill whose match
# rules cover the changed file (its cheat sheet, once per session), and queues
# review-eligible files for the Stop hook to audit. Routing is deterministic
# file-type matching; the haiku review itself is owned by skill_review.rb.
class SkillInject
  EVENT = 'PostToolUse'
  EDIT_TOOLS = %w[Edit Write MultiEdit NotebookEdit].freeze

  def initialize(event, skills: nil)
    @event = event
    @skills = skills
  end

  def emit(io = $stdout)
    return unless EDIT_TOOLS.include?(@event['tool_name'])

    path = changed_path
    return unless path

    matched = registry.select { |skill| skill.matches?(path) }
    return if matched.empty?

    enqueue_reviews(matched, path)
    surface(matched, io)
  end

  private

  def registry = @skills ||= SkillRegistry.load

  def changed_path
    input = @event['tool_input']
    return unless input.is_a?(Hash)

    input['file_path'] || input['notebook_path']
  end

  # Records every review-enabled match so the Stop hook reviews the batch. The
  # content hash lets the queue review each distinct version once and converge.
  def enqueue_reviews(skills, path)
    hash = content_hash(path)
    return unless hash

    queue = ReviewQueue.new(@event['session_id'])
    skills.select(&:review?).each { |skill| queue.add(skill.name, path, hash) }
  end

  def content_hash(path)
    Digest::SHA256.hexdigest(File.read(path))[0, 16]
  rescue StandardError
    nil
  end

  # Injects each matched skill's body at most once per session.
  def surface(skills, io)
    fresh = first_time(skills)
    return if fresh.empty?

    text = fresh.map { |skill| "[pst skill: #{skill.name}] active this session.\n\n#{skill.body}" }
                .join("\n\n---\n\n")
    io.puts(JSON.generate(hookSpecificOutput: { hookEventName: EVENT, additionalContext: text }))
  end

  def first_time(skills)
    store = SkillStore.new(@event['session_id'])
    fresh_names = store.fresh(skills.map(&:name))
    store.mark(fresh_names)
    skills.select { |skill| fresh_names.include?(skill.name) }
  end
end

SkillInject.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
