#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'

# Reads and writes the chosen merge mode for a session, keyed by session id
# under ~/.claude/cf/sessions. A blank session id is treated as non-persistable.
class MergeModeStore
  def initialize(session_id)
    @session_id = session_id.to_s
  end

  def mode
    return nil unless persistable? && File.exist?(path)

    File.read(path).strip
  end

  def write(mode)
    return unless persistable?

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{mode}\n")
  end

  private

  def persistable? = !@session_id.empty?

  def path = File.join(Dir.home, '.claude', 'cf', 'sessions', @session_id, 'merge-mode')
end
