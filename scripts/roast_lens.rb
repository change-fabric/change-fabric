# frozen_string_literal: true

require 'yaml'
require_relative 'skill_registry'

# Rubric lenses for cf:roast. Ruby routes, a haiku agent in the skill culls:
# `suggest` maps input paths (and a diff's +++ b/ paths) to candidate rubric
# skills; `resolve` turns explicit --lens names into Lens pairs.
module RoastLens
  Lens = Struct.new(:name, :body)

  class UnknownLens < StandardError; end

  DIFF_PATH = %r{^\+\+\+ b/(\S+)}

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
    paths = texts.flat_map { |path, body| [ path, *body.to_s.scan(DIFF_PATH).flatten ] }
    skills.select { |s| paths.any? { |p| s.matches?(p) } }.map { |s| "cf:#{bare(s.name)}" }.uniq.sort
  end
end
