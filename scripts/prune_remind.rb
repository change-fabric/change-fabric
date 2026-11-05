#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'stack_store'

# UserPromptSubmit hook: when the prompt says a merge already happened, surface
# the cf:prune skill so post-merge cleanup is offered without being asked.
#
# This is the automated half of cf:prune's hybrid trigger: the skill is still
# manually invocable, but a completed merge is a reliable cue that the local
# clone wants reconciling. It only matches past-tense, completed merges ("I
# merged #6", "PR is merged", "squash-merged") so an imperative ("merge this")
# or "merge conflict" does not fire it. The word boundary keeps "unmerged" out.
#
# Advisory only: it injects context, it does not act, so cf:prune's own guards
# still apply.
class PruneRemind
  EVENT = 'UserPromptSubmit'

  SIGNALS = [
    /\b(?:i|we)\s+(?:just\s+)?merged\b/i,
    /\bjust\s+merged\b/i,
    /\bmerged\s+(?:the\s+|that\s+|this\s+)?(?:prs?\b|pull\s+requests?\b|branch\b|#\d+|it\b)/i,
    /\b(?:prs?|pull\s+requests?)\b[^.\n]{0,40}\bmerged\b/i,
    /\b(?:got|was|were|has\s+been|have\s+been|had\s+been)\s+merged\b/i,
    /\bsquash[-\s]?merged\b/i
  ].freeze

  # Negation and not-yet phrasings assert the merge has not happened, so a bare
  # "merged" token in them must not fire. Checked before SIGNALS as an override.
  NEGATED = /\b(?:not|never|isn't|wasn't|hasn't|haven't|hadn't|un-?merged)\b[^.\n]{0,20}\bmerged\b|\bmerged\b[^.\n]{0,20}\byet\b/i

  def initialize(event, stack_records = nil)
    @event = event
    @stack_records = stack_records
  end

  def emit(io = $stdout)
    return unless merge_mentioned?

    io.puts(JSON.generate(hookSpecificOutput: { hookEventName: EVENT, additionalContext: context }))
  end

  private

  def prompt = @event['prompt'].to_s

  def merge_mentioned?
    return false if prompt.match?(NEGATED)

    SIGNALS.any? { |pattern| prompt.match?(pattern) }
  end

  def context = [ prune_context, *stack_context ].join(' ')

  # "merged #N" where N is the current PR of a stack being landed: the user's
  # message is the second merge signal next to stack_watch.rb, so say resume.
  def stack_context
    numbers = prompt.scan(/#(\d+)/).flatten
    slugs = stack_records.filter_map do |record|
      record['slug'] if numbers.include?(StackStore.current_pr(record)&.fetch('number', nil).to_s)
    end
    slugs.map { |slug| "PR stack #{slug} lists that PR as current: run /cf:sweep stack resume." }
  end

  def stack_records
    @stack_records ||= StackStore.unfinished_for_dir((@event['cwd'] || Dir.pwd).to_s)
  rescue StandardError
    []
  end

  def prune_context
    '[cf] This prompt reads as a completed merge. If a PR or branch just ' \
      'merged, run /cf:prune to fast-forward the trunk and prune merged ' \
      'branches and worktrees (local and remote). Honor its guards: never ' \
      'delete unmerged or dirty work, and never delete a remote branch, ' \
      'without an explicit AskUserQuestion approval.'
  end
end

PruneRemind.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
