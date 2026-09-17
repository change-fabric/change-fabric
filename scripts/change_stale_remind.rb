#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'guarded_command'
require_relative 'change_pr_facts'
require_relative 'change_stale_content_check'

# PreToolUse hook: on `gh pr merge`, warns when the PR head is missing a fix
# its base branch already has, the shape a stacked branch hits when its
# parent takes a review fix after the child was cut and the parent is squash
# merged (the child's commits never land on trunk, so ancestry checks see
# nothing wrong). Advisory only -- this is an `additionalContext` note, not a
# deny, because this hook is shared across concurrent sessions and a false
# positive (the PR legitimately rewrites the same lines, which merge-tree
# reports as a conflict, not staleness, and is excluded) must not block
# anyone's merge.
class ChangeStaleRemind
  EVENT = 'PreToolUse'

  def initialize(event)
    @event = event
  end

  def emit(io = $stdout)
    return unless @event['tool_name'] == 'Bash'
    return unless GuardedCommand.merge?(command)

    root = ChangePrFacts.repo_root or return
    pr = ChangePrFacts.resolve(command) or return
    base, head_sha = pr
    ChangePrFacts.fetch(root, base)

    result = ChangeStaleContentCheck.missing_from(head_sha, "origin/#{base}", dir: root)
    io.puts(JSON.generate(context(base, result))) unless result.missing_files.empty?
  rescue StandardError
    nil
  end

  private

  def command
    input = @event['tool_input']
    input.is_a?(Hash) ? input['command'].to_s : ''
  end

  def context(base, result)
    files = result.missing_files.join(', ')
    {
      hookSpecificOutput: {
        hookEventName: EVENT,
        additionalContext: "[cf:change] This PR head is missing content that '#{base}' already has and " \
          "the PR does not itself change, in: #{files}. This is the stacked-branch staleness shape (a " \
          "parent PR's review fix landed on '#{base}' after this branch was cut). Confirm this is stale " \
          "and not intentional before merging; rebase or merge '#{base}' in first if it is."
      }
    }
  end
end

ChangeStaleRemind.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
