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
  # A repo-relative path written in prose: segments joined by slashes, or a
  # single name with a short extension. URLs are stripped before scanning.
  PATH_TOKEN = %r{(?<![\w/.-])([\w.-]+(?:/[\w.-]+)+|[\w-]+\.[a-z]{1,6})(?![\w/])}
  URL = %r{\S+://\S+}

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

  # Opt-in, plan-aware routing: { "cf:name" => [reasons] }, keys sorted. With
  # the defaults it names exactly what `suggest` does. `plan_text: true` also
  # reads paths written in each body and the skills' `lens: keywords:`; a
  # `repo:` directory adds every rubric whose detect markers are present.
  # No cap, ranking or always-on here: that is the caller's policy.
  def suggest_with_reasons(texts, skills_dir = dir, plan_text: false, repo: nil)
    reasons = Hash.new { |h, k| h[k] = [] }
    names = rubrics(skills_dir).keys
    skills = SkillRegistry.load(skills_dir).select { |s| names.include?(bare(s.name)) }
    texts.each do |path, body|
      add_path_reasons(reasons, skills, [ path, *diff_paths(body) ])
      # An all_files skill matches any path, so a path named in prose says
      # nothing about it; only the input and diff paths route it.
      add_path_reasons(reasons, skills.reject(&:all_files?), named_paths(body)) if plan_text
    end
    add_keyword_reasons(reasons, texts, skills_dir) if plan_text
    add_detect_reasons(reasons, skills, repo) if repo
    reasons.keys.sort.to_h { |k| [ k, reasons[k].uniq ] }
  end

  def add_path_reasons(reasons, skills, paths)
    paths.uniq.each do |p|
      skills.each { |s| reasons["cf:#{bare(s.name)}"] << "path #{p}" if s.matches?(p) }
    end
  end

  # Paths written in a prose body: URLs removed first, and a sentence's
  # closing period trimmed off the token.
  def named_paths(body)
    body.to_s.gsub(URL, ' ').scan(PATH_TOKEN).flatten.map { |t| t.sub(/\.+\z/, '') }.reject(&:empty?).uniq
  end

  # { "cf:name" => [keywords] } from each rubric's optional `lens: keywords:`.
  def keywords(skills_dir = dir)
    Dir.glob(File.join(skills_dir, '*', 'SKILL.md')).sort.each_with_object({}) do |path, acc|
      meta, = parse(path)
      next unless meta.is_a?(Hash) && meta['group'] == 'rubrics'

      words = meta['lens'].is_a?(Hash) ? Array(meta['lens']['keywords']).map(&:to_s) : []
      acc["cf:#{bare(meta['name'])}"] = words unless words.empty?
    end
  end

  # Case-insensitive whole word, optional plural s, any whitespace run
  # between the words of a multi-word keyword.
  def keyword_pattern(word)
    inner = word.split(/\s+/).map { |w| Regexp.escape(w) }.join('\s+')
    /(?<![\w-])#{inner}s?(?![\w-])/i
  end

  def add_keyword_reasons(reasons, texts, skills_dir)
    corpus = texts.map { |_, body| body.to_s }.join("\n")
    keywords(skills_dir).each do |name, words|
      words.each { |w| reasons[name] << "keyword #{w.downcase}" if corpus.match?(keyword_pattern(w)) }
    end
  end

  # Only skills with explicit detect markers; the reason names the marker.
  def add_detect_reasons(reasons, skills, repo)
    skills.each do |skill|
      markers = skill.detect_markers
      next if markers.empty? || !skill.detected?(repo)

      hit = markers.find { |m| Dir.glob(File.join(repo, m)).any? } || markers.first
      reasons["cf:#{bare(skill.name)}"] << "detect #{hit}"
    end
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
