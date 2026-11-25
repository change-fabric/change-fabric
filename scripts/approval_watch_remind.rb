#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'guarded_command'

# PreToolUse (Bash): every human gate an agent opens needs a watcher that
# wakes the session on the decision. `approval_console.rb request --no-wait`
# only posts the request; `approval_console.rb record <id>` is the watcher: it
# blocks until the phone approves, denies or the request expires, records on
# approval, and exits nonzero (3 denied, 4 expired) otherwise. Run as a
# background Bash task, its exit wakes the agent. This hook warns, never
# denies, when a `request --no-wait` runs in the foreground (reminding the
# agent to start `record <id>` in the background at once) or a `record` runs
# in the foreground (which blocks the turn). It starts no process itself: a
# detached watcher would be a host daemon. Fails silent on error.
class ApprovalWatchRemind
  EVENT = 'PreToolUse'
  CONSOLE = 'approval_console.rb'

  REQUEST_NOTE = '[cf] Approval requested with --no-wait. Post the console link, then at once start ' \
                 '`approval_console.rb record <request_id>` as a background Bash task (run_in_background: true). ' \
                 'It blocks until the phone approves, denies or the request expires, records the receipt, and ' \
                 'wakes this session on exit (0 recorded, 3 denied, 4 expired). Never ask the human to type "approved".'
  RECORD_NOTE = '[cf] `approval_console.rb record` blocks until the phone decides. Run it with ' \
                'run_in_background: true so the turn is not blocked and the session is woken on exit ' \
                '(0 recorded, 3 denied, 4 expired).'

  def initialize(event) = @event = event

  def emit(io = $stdout)
    note = note_for(@event['tool_input'])
    io.puts(JSON.generate(hookSpecificOutput: { hookEventName: EVENT, additionalContext: note })) if note
  rescue StandardError
    nil
  end

  private

  def note_for(input)
    return unless @event['tool_name'] == 'Bash' && input.is_a?(Hash)
    return if input['run_in_background']

    tokens = GuardedCommand.tokens(input['command'])
    at = tokens.index { |token| File.basename(token) == CONSOLE }
    return unless at

    verb = tokens[(at + 1)..].find { |token| !token.start_with?('-') }
    return REQUEST_NOTE if verb == 'request' && tokens.include?('--no-wait')

    RECORD_NOTE if verb == 'record'
  end
end

if __FILE__ == $PROGRAM_NAME
  event = HookEvent.read
  HookEvent.instrument('approval_watch_remind', event) { ApprovalWatchRemind.new(event).emit }
end
