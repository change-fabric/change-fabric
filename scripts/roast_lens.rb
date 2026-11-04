# frozen_string_literal: true

require 'yaml'
require_relative 'skill_registry'

# Rubric lenses for cf:roast. Ruby routes, a haiku agent in the skill culls:
# `suggest` maps input paths (and a diff's --- a/ and +++ b/ paths) to candidate rubric
# skills; `resolve` turns explicit --lens names into Lens pairs.
module RoastLens
  Lens = Struct.new(:name, :body)

  class UnknownLens < StandardError; end

  # Every path-bearing diff record: ---/+++ headers (both sides: a deletion's
  # +++ is /dev/null, an addition's --- is), the diff --git line (the only one
  # a mode-only or binary change carries), and rename/copy records (the only
  # ones a pure rename or copy carries). Paths run to end of line, so a space
  # is part of the path; Git's C-quoted form is unquoted.
  HEADER = /^(?:\+\+\+|---) (?<path>"[ab]\/(?:[^"\\]|\\.)*"|[ab]\/.+?|\/dev\/null)\t?$/
  RECORD = /^(?:rename|copy) (?:from|to) (?<path>.+)$/
  GIT_LINE = /^diff --git (?<rest>.+)$/
  QUOTED_PAIR = /\A("(?:[^"\\]|\\.)*"|a\/.+?) ("(?:[^"\\]|\\.)*"|b\/.+)\z/
  ESCAPES = { 'a' => "\a", 'b' => "\b", 't' => "\t", 'n' => "\n", 'v' => "\v", 'f' => "\f", 'r' => "\r" }.freeze

  module_function

  def dir
    ENV.fetch('CF_SKILLS_DIR') { SkillRegistry.default_dir }
  end

  def bare(name) = name.to_s.delete_prefix('cf:')

  # Every group: rubrics skill under skills_dir, keyed by bare name.
  def rubrics(skills_dir = dir)
    Dir.glob(File.join(skills_dir, '*', 'SKILL.md')).sort.each_with_object({}) do |path, acc|
      meta, body = parse(path)
      next unless meta.is_a?(Hash) && meta['group'] == 'rubrics'

      name = bare(meta['name'])
      acc[name] = Lens.new("cf:#{name}", body.to_s.strip)
    end
  end

  def parse(path)
    front, body = SkillRegistry::Frontmatter.split(File.read(path))
    [ front && YAML.safe_load(front), body ]
  rescue StandardError
    [ nil, nil ]
  end

  # Names like "aws" or "cf:aws"; raises UnknownLens naming the bad one.
  def resolve(names, skills_dir = dir)
    table = rubrics(skills_dir)
    names.map { |n| bare(n) }.uniq.map do |n|
      table.fetch(n) do
        raise UnknownLens, "roast refused: --lens #{n} is not a rubric skill (known: #{table.keys.join(', ')})"
      end
    end
  end

  # Candidate lens names for the given [path, body] texts, deterministic order.
  def suggest(texts, skills_dir = dir)
    names = rubrics(skills_dir).keys
    skills = SkillRegistry.load(skills_dir).select { |s| names.include?(bare(s.name)) }
    paths = texts.flat_map { |path, body| [ path, *diff_paths(body) ] }
    skills.select { |s| paths.any? { |p| s.matches?(p) } }.map { |s| "cf:#{bare(s.name)}" }.uniq.sort
  end

  # Repo-relative paths named by a diff's path-bearing records.
  def diff_paths(body)
    body.to_s.each_line(chomp: true).flat_map do |line|
      if (m = HEADER.match(line)) then [ strip_side(unquote(m[:path])) ]
      elsif (m = RECORD.match(line)) then [ unquote(m[:path]) ]
      elsif (m = GIT_LINE.match(line)) then git_line_paths(m[:rest])
      else []
      end
    end.compact.uniq
  end

  # "a/x b/y": a quoted side splits cleanly; otherwise every " b/" is a
  # candidate split, since a path may itself contain a space or a " b/".
  def git_line_paths(rest)
    m = QUOTED_PAIR.match(rest)
    return [ m[1], m[2] ].map { |side| strip_side(unquote(side)) } if m && rest.include?('"')

    starts = (0...rest.length).select { |i| rest[i, 3] == ' b/' }
    starts.flat_map { |i| [ strip_side(rest[0...i]), strip_side(rest[(i + 1)..]) ] }
  end

  def strip_side(path)
    return nil if path.nil? || path == '/dev/null'

    path.sub(%r{\A[ab]/}, '')
  end

  def unquote(text)
    return text unless text.start_with?('"') && text.end_with?('"') && text.length > 1

    text[1..-2].b.gsub(/\\([0-7]{3}|.)/n) do
      code = Regexp.last_match(1)
      code.match?(/\A[0-7]{3}\z/) ? code.to_i(8).chr : ESCAPES.fetch(code, code)
    end.force_encoding(Encoding::UTF_8)
  end
end
