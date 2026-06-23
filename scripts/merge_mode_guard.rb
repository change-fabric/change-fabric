#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "merge_mode_store"

# Advisory guardrail, not airtight enforcement: a simple regex match on the
# Bash command. It catches the obvious cases (a bare `git push` / `gh pr merge`)
# and is trivially bypassable (env-var indirection, git -c, non-Bash tools). It
# exists to make an accidental violation of the chosen mode loud, not to sandbox.
class GuardedCommand
  PUSH = /\bgit\s+push\b/
  MERGE = /\bgh\s+pr\s+merge\b/

  FORBIDDEN = {
    "Local only"  => { PUSH => "git push", MERGE => "gh pr merge" },
    "Merge ready" => { MERGE => "gh pr merge" }
  }.freeze

  def initialize(command, mode)
    @command = command.to_s
    @mode = mode
  end

  def violation
    FORBIDDEN.fetch(@mode, {}).each do |pattern, action|
      return action if @command.match?(pattern)
    end
    nil
  end
end

class MergeModeGuard
  EVENT = "PreToolUse"

  def initialize(event)
    @event = event
  end

  def emit(io = $stdout)
    return unless @event["tool_name"] == "Bash"

    mode = MergeModeStore.new(@event["session_id"]).mode
    return unless mode

    action = GuardedCommand.new(command, mode).violation
    return unless action

    io.puts(JSON.generate(deny(action, mode)))
  end

  private

  def command
    input = @event["tool_input"]
    input.is_a?(Hash) ? input["command"] : nil
  end

  def deny(action, mode)
    {
      hookSpecificOutput: {
        hookEventName: EVENT,
        permissionDecision: "deny",
        permissionDecisionReason: "[pst] Merge mode is #{mode}: #{action} is not allowed. Run /pst to change the mode."
      }
    }
  end
end

if __FILE__ == $PROGRAM_NAME
  MergeModeGuard.new(HookEvent.read).emit
end
