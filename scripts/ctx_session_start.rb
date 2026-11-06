#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'ctx_paths'
require_relative 'ctx_surface'
require_relative 'stack_store'

# SessionStart hook: injects the project's cf:ctx context as additionalContext,
# reading the LOCAL cache only. The context is the roadmap, the focused plan in
# full, and everything else as one-line index entries. The selection is deterministic and budgeted, so
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
    text = [ ctx_markdown(event), stack_nudges(cwd(event)) ].reject(&:empty?).join("\n\n")
    io.puts(JSON.generate(context(text))) unless text.empty?
  rescue StandardError
    nil
  end

  def self.ctx_markdown(event)
    CtxPaths.assert_home!
    CtxSurface.render(CtxSurface.select(cwd: cwd(event)))
  rescue StandardError
    ''
  end

  # A PR stack outlives the session that started it, so every start in its repo
  # says where it stopped. The stack store is the source the ctx pointer
  # (stack-<slug>) points at; reading it directly names the PR.
  def self.stack_nudges(dir)
    StackStore.unfinished_for_dir(dir).filter_map do |record|
      pr = StackStore.current_pr(record)
      "[cf] PR stack #{record['slug']} is paused at ##{pr['number']}; run /cf:sweep stack resume" if pr
    end.join("\n")
  rescue StandardError
    ''
  end

  def self.cwd(event) = (event['cwd'] || Dir.pwd).to_s

  def self.context(text)
    { hookSpecificOutput: { hookEventName: EVENT, additionalContext: text } }
  end
end

CtxSessionStart.run(HookEvent.read) if __FILE__ == $PROGRAM_NAME
