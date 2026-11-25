#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative 'hook_event'
require_relative 'merge_mode_store'
require_relative 'merge_mode_slug'

# UserPromptSubmit hook: restates the active merge mode as context, but only
# when it adds something: once per session, when the mode changed since the last
# restatement, and again after a compaction (which drops the earlier statement).
# The last restated mode is a per-session marker, so a repeat turn is silent and
# the injected text stays byte-stable for the session.
class MergeModeRestate
  EVENT = 'UserPromptSubmit'
  MARKER = 'merge-mode-restated'

  def initialize(event)
    @event = event
  end

  def emit(io = $stdout)
    return forget if compaction?

    mode = MergeModeSlug.of(MergeModeStore.new(@event['session_id']).mode)
    return unless mode && stale?(mode)

    remember(mode)
    io.puts(JSON.generate(payload(mode)))
  end

  private

  # A compaction event only clears the marker; the next prompt restates.
  def compaction?
    @event['hook_event_name'] == 'PostCompact' || @event['source'] == 'compact'
  end

  def session = @event['session_id'].to_s

  def marker = File.join(Dir.home, '.claude', 'cf', 'sessions', session, MARKER)

  def stale?(mode)
    session.empty? || !File.exist?(marker) || File.read(marker).strip != mode
  end

  def remember(mode)
    return if session.empty?

    FileUtils.mkdir_p(File.dirname(marker))
    File.write(marker, "#{mode}\n")
  end

  def forget
    FileUtils.rm_f(marker) unless session.empty?
    nil
  end

  def payload(mode)
    { hookSpecificOutput: { hookEventName: EVENT, additionalContext: context(mode) } }
  end

  def context(mode)
    "[cf] Active merge mode: #{mode}. Honor it for this turn per the /cf rules."
  end
end

MergeModeRestate.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
