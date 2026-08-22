#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'away_store'
require_relative 'merge_mode_store'
require_relative 'merge_mode_slug'

# UserPromptSubmit hook: handles the six direct mode commands
# (/cf:away, /cf:active, /cf:local-only, /cf:merge-ready, /cf:admin-bypass,
# /cf:yolo) in one place, since they all key off the same single field
# (prompt) on the same single event. Writes AwayStore or MergeModeStore,
# injects a one-line confirmation, and separately injects the cf:plan
# refuse-to-start directive when away mode is active and the prompt begins
# with /cf:plan.
class ModeCommand
  EVENT = 'UserPromptSubmit'

  COMMAND_PATTERN = %r{\A\s*/cf:(away|active|local-only|merge-ready|admin-bypass|yolo)\b}
  PLAN_PATTERN = %r{\A\s*/cf:plan\b}

  AWAY_COMMANDS = %w[away active].freeze

  def initialize(event)
    @event = event
  end

  def emit(io = $stdout)
    lines = []
    lines << apply_command if command
    lines << plan_refusal if refuse_plan?
    return if lines.empty?

    io.puts(JSON.generate(payload(lines.join("\n"))))
  end

  private

  def prompt
    @event['prompt'].to_s
  end

  def session_id
    @event['session_id']
  end

  def command
    match = prompt.match(COMMAND_PATTERN)
    match && match[1]
  end

  def apply_command
    if AWAY_COMMANDS.include?(command)
      write_away(command)
    else
      write_merge_mode(command)
    end
  end

  def write_away(command)
    state = command == 'away' ? AwayStore::AWAY : AwayStore::ACTIVE
    AwayStore.new(session_id).write(state)
    if state == AwayStore::AWAY
      '[cf] Away mode is now on for this session. Do not ask questions; take the recommended/safe default and continue. Run /cf:active to end away mode.'
    else
      '[cf] Away mode is now off for this session. Ask normally again. Run /cf:away to step away.'
    end
  end

  def write_merge_mode(slug)
    MergeModeStore.new(session_id).write(slug)
    "[cf] Merge mode for this session is now #{slug}. Honor it per the /cf rules; " \
      'run /cf:local-only, /cf:merge-ready, /cf:admin-bypass, /cf:yolo, or /cf to change it.'
  end

  def refuse_plan?
    prompt.match?(PLAN_PATTERN) && AwayStore.new(session_id).away?
  end

  def plan_refusal
    '[cf] Away mode is active: refuse to start the cf:plan interview. Guessing its judgment calls ' \
      'defeats the point of running it. Tell the user to run /cf:active first, then re-run /cf:plan.'
  end

  def payload(context)
    { hookSpecificOutput: { hookEventName: EVENT, additionalContext: context } }
  end
end

ModeCommand.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
