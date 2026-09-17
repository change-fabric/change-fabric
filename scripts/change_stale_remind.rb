#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'guarded_command'
require_relative 'change_pr_facts'
require_relative 'change_stale_content_check'

# PreToolUse hook: on `gh pr merge`, warns when the PR head is missing a fix
# its base branch already has *in a file the PR itself also changes* -- the
# shape a stacked branch hits when its parent takes a review fix after the
# child was cut and the parent is squash merged (the child's commits never
# land on trunk, so ancestry checks see nothing wrong). Narrowed to files
# both sides touch (`require_base_changed`) because a squash merge only ever
# applies the PR's own diff: a file the PR never goes near cannot be reverted
# by merging it, so flagging every trunk change the PR happens not to touch
# is just noise that fires on nearly every PR under normal merge cadence.
# Advisory only -- this is an `additionalContext` note, not a deny, because
# this hook is shared across concurrent sessions and a false positive (the
# PR legitimately rewrites the same lines, which merge-tree reports as a
# conflict, not staleness, and is excluded) must not block anyone's merge.
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

    result = ChangeStaleContentCheck.missing_from(head_sha, "origin/#{base}", dir: root, require_base_changed: true)
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
        additionalContext: "[cf:change] This PR and '#{base}' both changed the same file(s) since this " \
          "branch was cut, and the two sides merge cleanly without a conflict: #{files}. A clean merge " \
          "here can still be semantically wrong even though nothing looks broken -- for example, this PR " \
          "calling a helper against a signature '#{base}' has since changed. Check these files against " \
          "'#{base}' before merging."
      }
    }
  end
end

ChangeStaleRemind.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
