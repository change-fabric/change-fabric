#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'digest'
require 'open3'
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

    # Enqueue on the structural match (gates skipped), so a file authored before
    # its require marker still enters the queue; the require/exclude gates are
    # applied at review time against the final tree (review_scope). Surfacing
    # stays gated to the project as it stands, so a non-matching project does not
    # see the cheat sheet.
    structural = registry.select { |skill| skill.matches?(path) }
    return if structural.empty?

    enqueue_reviews(structural, path)
    root = repo_root(path)
    surface(structural.select { |skill| skill.matches?(path, root: root) }, io)
  end

  private

  def registry = @skills ||= SkillRegistry.load

  def changed_path
    input = @event['tool_input']
    return unless input.is_a?(Hash)

    input['file_path'] || input['notebook_path']
  end

  # Project root for exclusion gating, resolved from the changed file's own
  # directory so a path in another repo is judged by that repo. Any git failure
  # yields nil; matches? then skips exclusion, so an unresolved root never
  # suppresses a skill. Suppression is the aggressive action and must not fire
  # on uncertainty.
  def repo_root(path)
    out, status = capture_git(File.dirname(path), 'rev-parse', '--show-toplevel')
    status&.success? ? out.strip : nil
  end

  # Records every match so the Stop hook reviews the batch. The content hash
  # lets the queue review each distinct version once and converge. Only files git
  # would carry off the machine are enqueued; surfacing the cheat sheet still
  # happens for any edit, but a scratchpad or git-ignored file must not arm the
  # gate, since the gate exists to review what a push or PR will publish.
  def enqueue_reviews(skills, path)
    return unless trackable?(path)

    hash = content_hash(path)
    return unless hash

    queue = ReviewQueue.new(@event['session_id'])
    skills.each { |skill| queue.add(skill.name, path, hash) }
  end

  # Trackable means inside a git work tree and not ignored. Both checks run git
  # from the file's own directory, so a path in another repo is judged by that
  # repo.
  def trackable?(path)
    dir = File.dirname(path)
    inside_work_tree?(dir) && !ignored?(dir, path)
  end

  def inside_work_tree?(dir)
    out, status = capture_git(dir, 'rev-parse', '--is-inside-work-tree')
    status&.success? && out.strip == 'true'
  end

  def ignored?(dir, path)
    _out, status = capture_git(dir, 'check-ignore', '-q', path)
    status&.success? || false
  end

  # Any git failure (no repo, no git) fails closed: a nil status reads as false
  # in both callers, so the file is treated as not trackable.
  def capture_git(dir, *args)
    Open3.capture2e('git', '-C', dir, *args)
  rescue StandardError
    [ '', nil ]
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

    text = fresh.map { |skill| "[cf skill: #{skill.name}] active this session.\n\n#{skill.body}" }
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
