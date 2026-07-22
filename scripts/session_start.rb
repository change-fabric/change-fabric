#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'merge_mode_store'

# SessionStart hook: asks for a merge mode, or restates one already chosen.
class MergeModeHook
  EVENT = 'SessionStart'

  ASK = <<~TEXT.strip
    [cf] Before responding to anything else, call the AskUserQuestion tool to set the session's MERGE MODE.

    Question: "How should I handle changes from this session?"
    Header: "Merge mode"
    Options:
      1. "Local only" - No push, no PR. Changes stay on disk.
      2. "Merge ready" - Push branch, open PR, ensure CI is green. The user merges manually.
      3. "Admin bypass" - Push branch, open PR, then squash-merge via `gh pr merge --squash --admin` once CI is green. No other quality passes.
      4. "Yolo" - Commit and push straight to the target branch (main, or whichever branch is in play). Never create a new PR; merging an existing PR is fine.

    After the user answers, acknowledge the choice in one line, then proceed. Apply the chosen mode for the rest of the session unless /cf changes it.
  TEXT

  def initialize(event)
    @event = event
  end

  def emit(io = $stdout)
    io.puts(JSON.generate(payload))
  end

  private

  def payload
    { hookSpecificOutput: { hookEventName: EVENT, additionalContext: directive } }
  end

  def directive
    mode = MergeModeStore.new(@event['session_id']).mode
    mode ? restate(mode) : ASK
  end

  def restate(mode)
    "[cf] Merge mode for this session is already set to #{mode}. Honor it per the /cf rules; run /cf to change it."
  end
end

MergeModeHook.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
