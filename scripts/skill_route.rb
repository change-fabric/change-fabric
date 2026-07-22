#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'skill_registry'

# CLI for the /cf:refactor command (copied to the shim bin but not wired as a
# hook): given a changeset's files, prints which auto-firing cf skills cover
# each, reusing the exact match rules the per-edit hooks use. The command
# resolves a scope to a file list, runs it through here, and applies each named
# skill's rubric. Paths come from ARGV, or newline-delimited stdin when ARGV is
# empty.
class SkillRoute
  def initialize(paths, skills: SkillRegistry.load)
    @paths = paths
    @skills = skills
  end

  def self.from(argv, input: $stdin, skills: SkillRegistry.load)
    raw = argv.empty? ? input.read.split("\n") : argv
    new(raw.map(&:strip).reject(&:empty?), skills: skills)
  end

  # skill name => sorted files it covers; skills matching nothing are absent.
  def by_skill
    covered = Hash.new { |hash, name| hash[name] = [] }
    @paths.each do |path|
      @skills.each { |skill| covered[skill.name] << path if skill.matches?(path) }
    end
    covered.transform_values(&:sort)
  end

  def render
    grouped = by_skill
    return 'No cf skills match the given files.' if grouped.empty?

    grouped.sort.map do |name, files|
      "#{name} (#{files.length}):\n" + files.map { |f| "  #{f}" }.join("\n")
    end.join("\n\n")
  end
end

puts SkillRoute.from(ARGV).render if __FILE__ == $PROGRAM_NAME
