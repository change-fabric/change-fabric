#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'guarded_command'
require_relative 'change_pr_facts'
require_relative 'change_stale_content_check'

# PostToolUse hook: after `gh pr merge` runs, re-fetches the base branch and
# checks that the PR head's content actually landed. A green CI run on the PR
# head, and a `gh pr merge` that reports success, both prove the code was
# good on that head; neither proves the merge commit carries it. A squash
# merge can silently omit files from the commit it produces (observed: a
# force-push landed, CI went green on that exact head, the resulting squash
# commit dropped two of its files) and nothing else in this toolkit is
# checking for that, because it is not a PR event -- it only exists once the
# merge has already happened. Advisory only, same reasoning as
# change_stale_remind.rb: loud and specific, never fatal, since the merge has
# already gone through.
class ChangePostMergeCheck
  EVENT = 'PostToolUse'

  def initialize(event)
    @event = event
  end

  def emit(io = $stdout)
    return unless @event['tool_name'] == 'Bash'
    return unless GuardedCommand.merge?(command)

    root = ChangePrFacts.repo_root or return
    pr = ChangePrFacts.resolve(command, state: 'MERGED') or return
    base, head_sha = pr
    ChangePrFacts.fetch(root, base)

    result = ChangeStaleContentCheck.missing_from("origin/#{base}", head_sha, dir: root)
    io.puts(JSON.generate(context(base, head_sha, result))) unless result.missing_files.empty?
  rescue StandardError
    nil
  end

  private

  def command
    input = @event['tool_input']
    input.is_a?(Hash) ? input['command'].to_s : ''
  end

  def context(base, head_sha, result)
    files = result.missing_files.join(', ')
    {
      hookSpecificOutput: {
        hookEventName: EVENT,
        additionalContext: "[cf:change] '#{base}' is missing content from the just-merged PR head " \
          "#{head_sha[0, 12]} in: #{files}. This is the squash-drop shape (the merge commit did not " \
          "carry everything the merged head had) -- CI green on the head and a successful merge do not " \
          "guarantee this. Diff those files against #{head_sha[0, 12]} and open a follow-up PR if content " \
          "is genuinely missing."
      }
    }
  end
end

ChangePostMergeCheck.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
