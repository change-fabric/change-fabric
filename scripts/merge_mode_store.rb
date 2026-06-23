#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"

# Parse a hook event from stdin. Hooks fire on every event, so a bad or
# unexpected payload must fail silent (empty event), never crash the session.
module HookEvent
  def self.read(io = $stdin)
    raw = io.read.to_s
    return {} if raw.empty?

    parsed = JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end
end

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

  def path = File.join(Dir.home, ".claude", "pst", "sessions", @session_id, "merge-mode")
end
