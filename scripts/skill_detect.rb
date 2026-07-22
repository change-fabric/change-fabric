#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative 'hook_event'
require_relative 'skill_registry'
require_relative 'skill_store'

# SessionStart hook: deterministically fingerprints the working directory by its
# marker files (Gemfile, *.gemspec, ...) and announces which auto-skills apply
# this session, once. This is the cheap, reliable counterpart to per-edit
# routing: project type is a file-presence question, not one worth an LLM call.
# Per-edit surfacing still fires on file type regardless, so a missed
# fingerprint never suppresses a skill.
class SkillDetect
  EVENT = 'SessionStart'

  def initialize(event, skills: nil)
    @event = event
    @skills = skills
  end

  def emit(io = $stdout)
    active = registry.select { |skill| skill.detected?(cwd) }
    fresh = announce(active.map(&:name))
    return if fresh.empty?

    io.puts(JSON.generate(context(fresh)))
  end

  private

  def registry = @skills ||= SkillRegistry.load

  def cwd = (@event['cwd'] || Dir.pwd).to_s

  def announce(names)
    store = SkillStore.new(@event['session_id'], 'skills-announced')
    fresh = store.fresh(names)
    store.mark(fresh)
    fresh
  end

  def context(names)
    text = "[cf] Auto-skills active for this project: #{names.join(', ')}. " \
           'Their guidance will be surfaced automatically as you change matching files.'
    { hookSpecificOutput: { hookEventName: EVENT, additionalContext: text } }
  end
end

SkillDetect.new(HookEvent.read).emit if __FILE__ == $PROGRAM_NAME
