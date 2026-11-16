#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require_relative 'plan_check'

# Keeps this repo's docs to the living set named in PRINCIPLES.md. Every check
# is a pure function over file contents and a path-exists predicate, so tests
# feed fixtures; `DocsCheck.run(root)` wires them to the real tree. Every check
# runs and reports, so one invocation names everything wrong at once.
module DocsCheck
  LIVING = %w[ARCHITECTURE.md PRINCIPLES.md AGENTS.md].freeze
  CAPS = { 'ARCHITECTURE.md' => 250, 'PRINCIPLES.md' => 150, 'AGENTS.md' => 80 }.freeze
  SHIM = "@AGENTS.md\n"

  # A new markdown file has to be added here on purpose. Skill and walkthrough
  # entries name the exact shapes in use, so a stray notes.md or roast log fails.
  # `scripts/CF_TEAM_SETUP.md` is a one-line pointer kept because the frozen spec
  # text cites it. `platform/**` goes when platform/ does.
  ALLOWED = %w[
    README.md AGENTS.md CLAUDE.md ARCHITECTURE.md PRINCIPLES.md RELEASING.md
    CHANGELOG.md CHANGE.md NOTICE* LICENSE* site/DESIGN.md site/README.md
    site/src/archive/*.md skills/README.md skills/*/SKILL.md skills/*/VALIDATION.md
    skills/*/reference/**/*.md skills/ctx/reference.md skills/prototype/fixtures/*/CONTRACT.md
    workflows/modes/*.md scripts/CF_TEAM_SETUP.md
    telemetry/infra/lambda/SIGNING.md */infra/README.md walkthrough/*/brief.md
    walkthrough/*/storyboard.md walkthrough/*/ASSUMPTIONS.md
    test/fixtures/**/* platform/**/*
  ].freeze

  EXTENSIONS = %w[rb md json yml yaml ts tsx js mjs tf sh txt].freeze
  TAG = %r{\A(skills|spec|site|app|image|change-schema)/v}
  LINK = /\]\(([^)\s]+)\)/
  CODE = /`([^`\n]+)`/

  module_function

  def unlisted(tracked)
    tracked.reject { |path| ALLOWED.any? { |glob| File.fnmatch?(glob, path, File::FNM_PATHNAME) } }
           .map { |path| "#{path}: not in the living doc allowlist (scripts/docs_check.rb)" }
  end

  def shim(text)
    text == SHIM ? [] : [ 'CLAUDE.md: must contain exactly "@AGENTS.md"' ]
  end

  def over_cap(name, text)
    cap = CAPS.fetch(name)
    count = text.lines.size
    count > cap ? [ "#{name}: #{count} lines, cap is #{cap}" ] : []
  end

  def glyphs(name, text)
    text.lines.each_with_index.filter_map do |line, index|
      "#{name}:#{index + 1}: slop glyph" if line.match?(PlanCheck::GLYPHS)
    end
  end

  # A token is checked when it reads as a repo path: it has a slash or a known
  # extension, and is not a URL, home or absolute path, glob, placeholder, or tag.
  def path_like?(token)
    return false if token.match?(%r{\s|://|[*<>{}$]|\A[~/#]}) || token.match?(TAG)

    token.include?('/') || EXTENSIONS.include?(File.extname(token).delete('.'))
  end

  # Bare file names (a hook table cell) resolve by basename anywhere in the repo.
  def broken_paths(name, text, exists)
    links = text.scan(LINK).flatten.reject { |t| t.match?(%r{://|\A#|\Amailto:}) }.map { |t| t.split('#').first }
    codes = text.scan(CODE).flatten.select { |t| path_like?(t) }
    (links + codes).uniq.reject { |t| exists.call(t) }.map { |t| "#{name}: #{t} does not exist" }
  end

  def enforcers(text, exists)
    sections = text.split(/^## /).drop(1)
    sections.flat_map do |section|
      title = section.lines.first.strip
      found = section.lines.grep(/\AEnforcer:/)
      next [ "PRINCIPLES.md: \"#{title}\" needs exactly one Enforcer: line" ] unless found.size == 1

      value = found.first.delete_prefix('Enforcer:').strip
      next [] if value == 'advisory'

      value.split(',').map(&:strip).reject { |path| exists.call(path) }
           .map { |path| "PRINCIPLES.md: \"#{title}\" enforcer #{path} does not exist" }
    end
  end

  def run(root)
    tracked, = Open3.capture2('git', '-C', root, 'ls-files', '-z')
    files = tracked.split("\0")
    basenames = files.to_set { |f| File.basename(f) }
    exists = lambda do |path|
      path.include?('/') ? File.exist?(File.join(root, path)) : basenames.include?(path)
    end
    read = ->(name) { File.exist?(File.join(root, name)) ? File.read(File.join(root, name)) : '' }

    problems = unlisted(files.grep(/\.md\z/)) + shim(read.call('CLAUDE.md'))
    LIVING.each do |name|
      text = read.call(name)
      problems.concat(over_cap(name, text), glyphs(name, text), broken_paths(name, text, exists))
    end
    problems + enforcers(read.call('PRINCIPLES.md'), exists)
  end
end

if $PROGRAM_NAME == __FILE__
  problems = DocsCheck.run(File.expand_path('..', __dir__))
  puts problems
  exit(problems.empty? ? 0 : 1)
end
