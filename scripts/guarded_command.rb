#!/usr/bin/env ruby
# frozen_string_literal: true

# Advisory guardrail, not airtight enforcement: a simple regex match on the
# Bash command. It catches the obvious cases (a bare `git push` / `gh pr merge`)
# and is trivially bypassable (env-var indirection, git -c, non-Bash tools). It
# exists to make an accidental violation of the chosen mode loud, not to sandbox.
class GuardedCommand
  PUSH = /\bgit\s+push\b/
  MERGE = /\bgh\s+pr\s+merge\b/

  FORBIDDEN = {
    'Local only' => { PUSH => 'git push', MERGE => 'gh pr merge' },
    'Merge ready' => { MERGE => 'gh pr merge' }
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
