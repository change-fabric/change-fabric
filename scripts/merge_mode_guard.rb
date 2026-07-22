#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'merge_mode_store'
require_relative 'guarded_command'

# PreToolUse hook: denies a Bash command that violates the session's merge mode.
class MergeModeGuard
  EVENT = 'PreToolUse'

  def initialize(event)
    @event = event
  end

  def emit(io = $stdout)
    return unless @event['tool_name'] == 'Bash'

    mode = MergeModeStore.new(@event['session_id']).mode
    return unless mode

    action = GuardedCommand.new(command, mode, branch: branch_for(command)).violation
    return unless action

    io.puts(JSON.generate(deny(action, mode)))
  end

  private

  def command
    input = @event['tool_input']
    input.is_a?(Hash) ? input['command'] : nil
  end

  # Only shell out for pushes, so the common Bash command pays nothing.
  def branch_for(command)
    return nil unless GuardedCommand.push?(command)

    current_branch
  end

  def current_branch
    out = `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
    out.empty? ? nil : out
  rescue StandardError
    nil
  end

  def deny(action, mode)
    {
      hookSpecificOutput: {
        hookEventName: EVENT,
        permissionDecision: 'deny',
        permissionDecisionReason: "[pst] Merge mode is #{mode}: #{action} is not allowed. Run /pst to change the mode."
      }
    }
  end
end

MergeModeGuard.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
