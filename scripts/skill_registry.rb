#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

# Loads auto-firing skills from a skills directory and answers which ones apply
# to a changed file or to the current project. A skill opts into auto-firing by
# carrying an `auto:` block in its SKILL.md frontmatter; skills without one (the
# plain user-invocable kind) are ignored here. Everything fails silent: a bad
# manifest yields no skill, never a crash, because this runs inside hooks.
module SkillRegistry
  # The runtime install lives at ~/.claude/skills; from a hook in
  # ~/.claude/pst/bin that is two levels up. Tests pass an explicit dir.
  def self.default_dir = File.expand_path('../../skills', __dir__)

  def self.load(dir = default_dir)
    Dir.glob(File.join(dir, '*', 'SKILL.md')).filter_map { |path| Skill.parse(path) }
  end

  # One auto-firing skill: its match rules plus the body to surface.
  class Skill
    def self.parse(path)
      front, body = Frontmatter.split(File.read(path))
      meta = front && YAML.safe_load(front)
      return unless meta.is_a?(Hash) && meta['auto'].is_a?(Hash)

      new(meta, body)
    rescue StandardError
      nil
    end

    def initialize(meta, body)
      @meta = meta
      @auto = meta['auto']
      @body = body.to_s.strip
    end

    def name = @meta['name'].to_s
    def review? = @auto['review'] == true
    def universal? = @auto['universal'] == true
    def body = @body

    def matches?(path)
      base = File.basename(path.to_s)
      ext = File.extname(base).delete_prefix('.').downcase
      extensions.include?(ext) || basenames.include?(base)
    end

    def detected?(dir)
      return true if universal?

      detect.any? { |pattern| Dir.glob(File.join(dir, pattern)).any? }
    end

    private

    def extensions = Array(@auto['extensions']).map { |e| e.to_s.downcase }
    def basenames  = Array(@auto['basenames']).map(&:to_s)
    def detect     = Array(@auto['detect']).map(&:to_s)
  end

  # Splits a `---\n...\n---\n` YAML frontmatter block off the document body.
  module Frontmatter
    PATTERN = /\A---\s*\n(.*?\n)---\s*\n?(.*)\z/m

    def self.split(text)
      match = text.match(PATTERN)
      match ? [ match[1], match[2] ] : [ nil, text ]
    end
  end
end
