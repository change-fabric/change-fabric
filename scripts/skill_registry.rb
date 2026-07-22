#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'
require 'json'

# Loads auto-firing skills from a skills directory and answers which ones apply
# to a changed file or to the current project. A skill opts into auto-firing by
# carrying an `auto:` block in its SKILL.md frontmatter; skills without one (the
# plain user-invocable kind) are ignored here. Everything fails silent: a bad
# manifest yields no skill, never a crash, because this runs inside hooks.
module SkillRegistry
  # What `all_code: true` matches. Centralized so a code-wide skill declares
  # intent (`all_code`) instead of re-listing extensions in its frontmatter.
  CODE_EXTENSIONS = %w[
    rb rake gemspec ru py js jsx mjs cjs ts tsx mts cts go rs java kt kts c h cc cpp hpp
    cs php swift scala clj cljs ex exs erl hs ml sh bash zsh sql lua dart groovy
    r jl vue svelte
  ].freeze

  # fnmatch flags for `paths` rules. PATHNAME keeps * and ? inside one path
  # segment (so `.github/workflows/*.yml` cannot leak across directories);
  # EXTGLOB enables `{yml,yaml}`; DOTMATCH lets a glob cross dot-dirs like
  # `.github`. Centralized so per-file glob matching stays consistent.
  PATH_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH

  # The runtime install lives at ~/.claude/skills; from a hook in
  # ~/.claude/cf/bin that is two levels up. Tests pass an explicit dir.
  def self.default_dir = File.expand_path('../../skills', __dir__)

  # Union of dependency and devDependency names across every package.json in the
  # tree (monorepo-aware), or nil when none could be read. Memoized per dir for
  # the life of the process: a hook is one process, so this collapses the repeated
  # glob the dep-gated skills would otherwise each run, and never goes stale.
  def self.project_deps(dir)
    @project_deps ||= {}
    return @project_deps[dir] if @project_deps.key?(dir)

    @project_deps[dir] = load_project_deps(dir)
  end

  def self.load_project_deps(dir)
    files = Dir.glob(File.join(dir, '**', 'package.json'), File::FNM_DOTMATCH)
               .reject { |p| p.split(File::SEPARATOR).include?('node_modules') }
    parsed = files.filter_map { |path| dep_keys(path) }
    parsed.empty? ? nil : parsed.flatten.uniq
  rescue SystemCallError
    nil
  end

  # Dependency + devDependency names for one package.json, or nil if it cannot be
  # read or parsed (that file then contributes nothing to the union).
  def self.dep_keys(path)
    pkg = JSON.parse(File.read(path))
    return nil unless pkg.is_a?(Hash)

    %w[dependencies devDependencies].flat_map { |section| (pkg[section] || {}).keys }
  rescue StandardError
    nil
  end

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
    def all_code? = @auto['all_code'] == true
    def all_files? = @auto['all_files'] == true
    def body = @body

    # `root`, when given, is the project root used to evaluate the require and
    # exclude gates. It is optional so callers without project context (the CLI,
    # unit tests, the structural enqueue) match exactly as before; only a gated
    # caller passes it, and only there can a conflicting or absent stack suppress
    # a skill.
    def matches?(path, root: nil)
      return false if gated?(root)
      return true if all_files?

      base = File.basename(path.to_s)
      ext = File.extname(base).delete_prefix('.').downcase
      return true if all_code? && CODE_EXTENSIONS.include?(ext)

      extensions.include?(ext) || basenames.include?(base) || path_match?(path.to_s)
    end

    # Gate-only predicate, exposed so the Stop-hook and PR-gate review can apply
    # the same suppression against the final tree. A nil root is never gated (fail
    # open), matching matches?: suppression must not fire on an unknown project.
    def gated?(root)
      return false unless root

      excluded?(root) || !required?(root)
    end

    def detected?(dir)
      return false if excluded?(dir)
      return false unless required?(dir)
      return true if all_files? || all_code?

      detect.any? { |pattern| Dir.glob(File.join(dir, pattern)).any? }
    end

    private

    # A `paths` glob fires if it matches the path directly or as a suffix; the
    # "**/" prefix anchors it to any segment boundary, so one rule works for the
    # absolute paths the hook passes and the repo-relative paths the CLI passes.
    def path_match?(path)
      paths.any? do |glob|
        g = normalize(glob)
        File.fnmatch?(g, path, PATH_FLAGS) || File.fnmatch?("**/#{g}", path, PATH_FLAGS)
      end
    end

    # Ruby's fnmatch treats a trailing `**` as a single segment (unlike
    # Dir.glob), so `drizzle/**` would miss nested files; rewrite it to the
    # recursive form so the glob means what it reads as.
    def normalize(glob)
      glob.end_with?('/**') ? "#{glob}/*" : glob
    end

    # Suppression signal: any project file matching an `exclude` glob means a
    # conflicting stack is present, so this skill does not apply. An empty
    # `exclude` (every skill today) is always false, preserving behavior.
    def excluded?(dir)
      marker?(dir, exclude)
    end

    # Positive gate: when `require` is set, the skill applies only if the project
    # satisfies a marker. A marker is either a file-presence glob or a `{dep: [...]}`
    # entry naming npm packages; any one satisfier passes. Empty `require` (most
    # skills) is always satisfied.
    def required?(dir)
      return true if require_globs.empty? && require_deps.empty?
      return true if require_globs.any? && marker?(dir, require_globs)
      return true if require_deps.any? && deps_present?(dir)

      false
    end

    # Satisfied when any required dep appears in the project's package.json deps.
    # An indeterminate tree (no readable package.json) returns true: like every
    # gate here, an unknown project must not suppress.
    def deps_present?(dir)
      deps = SkillRegistry.project_deps(dir)
      return true if deps.nil?

      require_deps.any? { |name| deps.include?(name) }
    end

    # True when any glob in `patterns` matches a file present under `dir`.
    def marker?(dir, patterns)
      patterns.any? { |pattern| Dir.glob(File.join(dir, pattern)).any? }
    end

    def extensions = Array(@auto['extensions']).map { |e| e.to_s.downcase }
    def basenames  = Array(@auto['basenames']).map(&:to_s)
    def detect     = Array(@auto['detect']).map(&:to_s)
    def paths      = Array(@auto['paths']).map(&:to_s)
    def exclude    = Array(@auto['exclude']).map(&:to_s)

    # `require` entries are either file-presence globs (String) or content
    # markers (`{dep: [names]}`). Partition by type so each is checked its own way.
    def require_entries = Array(@auto['require'])
    def require_globs   = require_entries.grep(String).map(&:to_s)
    def require_deps    = require_entries.grep(Hash).flat_map { |h| Array(h['dep'] || h[:dep]) }.map(&:to_s)
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
