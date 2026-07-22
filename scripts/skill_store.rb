#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'

# Per-session memory of which auto-skills have already been surfaced, so the
# shim injects each one's cheat sheet at most once a session instead of on every
# edit. Keyed by session id under ~/.claude/cf/sessions, alongside merge-mode.
# A blank session id is treated as non-persistable (nothing is recorded, so
# everything reads as not-yet-surfaced and the caller still functions).
class SkillStore
  def initialize(session_id, key = 'skills-surfaced')
    @session_id = session_id.to_s
    @key = key
  end

  def fresh(names)
    names - recorded
  end

  def mark(names)
    return if !persistable? || names.empty?

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{(recorded | names).join("\n")}\n")
  end

  private

  def recorded
    return [] unless persistable? && File.exist?(path)

    File.read(path).split("\n").map(&:strip).reject(&:empty?)
  end

  def persistable? = !@session_id.empty?

  def path = File.join(Dir.home, '.claude', 'cf', 'sessions', @session_id, @key)
end
