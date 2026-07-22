#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'ctx_paths'
require_relative 'ctx_surface'

# SessionStart hook: injects the project's cf:ctx context (roadmap, the focused
# plan in full, everything else as one-line index entries) as additionalContext,
# reading the LOCAL cache only. The selection is deterministic and budgeted, so
# this stays cheap enough to run on every start. It mirrors skill_detect.rb: a
# library does the work, this entrypoint just reads, renders, and fails silent.
#
# A context-surfacing hook must never crash or block a session, so every path
# ends in "emit what we can, never raise." The backgrounded remote pull (sync
# engine, a later phase) is fired separately and is not part of this synchronous
# local select.
class CtxSessionStart
  EVENT = 'SessionStart'

  def self.run(event, io = $stdout)
    CtxPaths.assert_home!
    md = CtxSurface.render(CtxSurface.select(cwd: cwd(event)))
    io.puts(JSON.generate(context(md))) unless md.empty?
  rescue StandardError
    nil
  end

  def self.cwd(event) = (event['cwd'] || Dir.pwd).to_s

  def self.context(text)
    { hookSpecificOutput: { hookEventName: EVENT, additionalContext: text } }
  end
end

CtxSessionStart.run(HookEvent.read) if __FILE__ == $PROGRAM_NAME
