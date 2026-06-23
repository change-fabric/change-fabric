#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "merge_mode_store"

class MergeModeHook
  EVENT = "SessionStart"

  ASK = <<~TEXT.strip
    [pst] Before responding to anything else, call the AskUserQuestion tool to set the session's MERGE MODE.

    Question: "How should I handle changes from this session?"
    Header: "Merge mode"
    Options:
      1. "Local only" — No push, no PR. Changes stay on disk.
      2. "Merge ready" — Push branch, open PR, ensure CI is green. The user merges manually.
      3. "Admin bypass" — Push branch, open PR, then squash-merge via `gh pr merge --squash --admin` once CI is green. No other quality passes.

    After the user answers, acknowledge the choice in one line, then proceed. Apply the chosen mode for the rest of the session unless /pst changes it.
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
    mode = MergeModeStore.new(@event["session_id"]).mode
    mode ? restate(mode) : ASK
  end

  def restate(mode)
    "[pst] Merge mode for this session is already set to #{mode}. Honor it per the /pst rules; run /pst to change it."
  end
end

if __FILE__ == $PROGRAM_NAME
  MergeModeHook.new(HookEvent.read).emit
end
