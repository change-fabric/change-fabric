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

    action = GuardedCommand.new(command, mode).violation
    return unless action

    io.puts(JSON.generate(deny(action, mode)))
  end

  private

  def command
    input = @event['tool_input']
    input.is_a?(Hash) ? input['command'] : nil
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
