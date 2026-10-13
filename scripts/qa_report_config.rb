#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'change_frontmatter'

# Reads the top-level qa_report: key (schema 0.13.0) out of a repo's root
# CHANGE.md: the QA coverage report's title, trunk branch, brand, CI import
# globs, opt-in repo copy directory and history retention.
#
# Read straight from the frontmatter through ChangeFrontmatter, never through
# ChangeConfig, the same rule inbox_root follows, so a malformed
# change_config: or change_policy: block never affects the report and a
# malformed qa_report: never affects an audit lane. Root-only: an app file
# still accepts only change_config:.
#
# Never raises. Each malformed field falls back to its default and adds a
# warning naming the dotted field; any unexpected failure (an unreadable file,
# a frontmatter that will not parse) yields the defaults plus one warning.
module QaReportConfig
  KEY = 'qa_report'
  DEFAULT_MAX_RUNS = 200
  # The coverage data file's name (ChangeCoverageStore::DATA_FILE), named here
  # for the repo copy's .gitattributes check without loading the store.
  DATA_FILE = 'report-data.js'
  MAX_RUNS_RANGE = (10..5000)
  THEMES = %w[light dark].freeze
  SLOTS = %w[ground ink accent].freeze
  IMPORT_FORMATS = {
    'coverage' => %w[cobertura jacoco lcov],
    'test_results' => %w[junit testng]
  }.freeze

  HEX = /\A#(\h{3}|\h{6})\z/
  FONT_FAMILY = /\A[A-Za-z0-9 ,'"-]+\z/
  CONTROL = /[[:cntrl:]]/
  BRANCH_FORBIDDEN = %r{[[:cntrl:][:space:]~^:?*\[\\]|\.\.|@\{|//}

  TOP_KEYS = %w[title trunk brand imports repo_copy history].freeze
  BRAND_KEYS = %w[name logo logo_dark font colors].freeze

  Brand = Data.define(:name, :logo, :logo_dark, :font_family, :light, :dark)
  Imports = Data.define(:coverage, :test_results)
  Settings = Data.define(:declared, :title, :trunk, :brand, :imports, :repo_copy_dir, :max_runs, :warnings)

  module_function

  # project: the registry project name used for the default brand name and
  # title. When omitted it is read raw from change_config.project, else the
  # repo directory name.
  def load(repo_root, project: nil)
    path = File.join(repo_root, 'CHANGE.md')
    front = ChangeFrontmatter.parse_file(path)
    project ||= default_project(front, repo_root)
    warnings = []
    warnings << "#{KEY}: CHANGE.md frontmatter could not be parsed; using defaults" if unparsed_key?(path, front)
    Reader.new(front[KEY], repo_root, project, warnings).settings
  rescue StandardError => e
    defaults(project || File.basename(File.expand_path(repo_root)),
             [ "#{KEY}: could not be read (#{e.class}: #{e.message}); using defaults" ])
  end

  def defaults(project, warnings = [])
    Settings.new(
      declared: false, title: "#{project} QA coverage", trunk: nil,
      brand: Brand.new(name: project, logo: nil, logo_dark: nil, font_family: nil, light: nil, dark: nil),
      imports: Imports.new(coverage: [], test_results: []),
      repo_copy_dir: nil, max_runs: DEFAULT_MAX_RUNS, warnings: warnings
    )
  end

  # The doctor summary: one line describing the resolved settings, then one
  # `warning:` line per fallback taken.
  def doctor_lines(repo_root, project: nil)
    settings = load(repo_root, project: project)
    [ summary_line(settings) ] + settings.warnings.map { |w| "warning: #{w}" }
  end

  # The repo copy's data file is rewritten whole on each build, so two
  # branches that both rebuilt it conflict on merge unless git union-merges it
  # (the reader dedupes by id). When repo_copy.dir is set and .gitattributes
  # lacks that rule, a warning and the line to add; else nothing. Never writes
  # .gitattributes itself.
  def gitattributes_lines(repo_root, dir)
    return [] if dir.to_s.empty?

    rule = "#{dir.to_s.delete_suffix('/')}/#{DATA_FILE} merge=union"
    path = File.join(repo_root, '.gitattributes')
    return [] if File.file?(path) && File.readlines(path, chomp: true).any? { |line| line.split.join(' ') == rule }

    [ "warning: #{KEY}.repo_copy.dir: .gitattributes does not union-merge the repo copy; add this line:",
      "  #{rule}" ]
  end

  def summary_line(settings)
    return "#{KEY}: (not declared, neutral brand)" unless settings.declared

    imports = settings.imports
    "#{KEY}: #{settings.title}, brand #{settings.brand.name}, " \
      "#{imports.coverage.size} coverage import(s), #{imports.test_results.size} test-result import(s), " \
      "repo copy #{settings.repo_copy_dir || 'off'}, max_runs #{settings.max_runs}"
  end

  def default_project(front, repo_root)
    config = front['change_config']
    raw = config.is_a?(Hash) ? config['project'] : nil
    raw.is_a?(String) && !raw.strip.empty? ? raw.strip : File.basename(File.expand_path(repo_root))
  end

  # ChangeFrontmatter swallows a YAML syntax error into {}. A qa_report: line
  # in a file whose frontmatter came back empty means the key was written but
  # could not be read, which deserves a warning rather than silence.
  def unparsed_key?(path, front)
    front.empty? && File.file?(path) && File.read(path).match?(/^#{KEY}:/)
  end

  # Validates one qa_report: mapping. Every check appends to @warnings and
  # returns the default instead of raising.
  class Reader
    def initialize(raw, repo_root, project, warnings)
      @raw = raw
      @root = repo_root
      @project = project
      @warnings = warnings
    end

    def settings
      return QaReportConfig.defaults(@project, @warnings) if @raw.nil?
      unless @raw.is_a?(Hash)
        warn_field(KEY, 'expected a mapping; using defaults')
        return QaReportConfig.defaults(@project, @warnings)
      end

      unknown_keys(@raw, TOP_KEYS, KEY)
      brand = read_brand(section('brand'))
      Settings.new(
        declared: true,
        title: text(@raw['title'], 'title', max: 120) || "#{brand.name} QA coverage",
        trunk: trunk(@raw['trunk']),
        brand: brand,
        imports: read_imports(section('imports')),
        repo_copy_dir: repo_copy_dir(section('repo_copy')['dir']),
        max_runs: max_runs(section('history')['max_runs']),
        warnings: @warnings
      )
    end

    private

    def warn_field(field, message) = @warnings << "#{field}: #{message}"

    def dotted(field) = field.start_with?(KEY) ? field : "#{KEY}.#{field}"

    # A nested mapping under qa_report:, or {} with a warning when it is
    # present but not a mapping.
    def section(name, parent = @raw, prefix = name)
      value = parent[name]
      return {} if value.nil?
      return value if value.is_a?(Hash)

      warn_field(dotted(prefix), 'expected a mapping; ignored')
      {}
    end

    def unknown_keys(hash, allowed, prefix)
      (hash.keys.map(&:to_s) - allowed).each { |key| warn_field(dotted("#{prefix}.#{key}"), 'unknown field; ignored') }
    end

    def text(value, field, max:)
      return nil if value.nil?

      unless value.is_a?(String) && !value.strip.empty? && value.length <= max && !value.match?(CONTROL)
        warn_field(dotted(field), "expected a non-empty string of at most #{max} characters without control characters; using the default")
        return nil
      end
      value.strip
    end

    def trunk(value)
      return nil if value.nil?

      name = value.is_a?(String) ? value.strip : ''
      if name.empty? || name.length > 200 || name.match?(BRANCH_FORBIDDEN) || name.start_with?('-', '/') ||
         name.end_with?('/', '.', '.lock')
        warn_field(dotted('trunk'), 'expected a branch name; using the origin/HEAD default')
        return nil
      end
      name
    end

    def read_brand(brand)
      unknown_keys(brand, BRAND_KEYS, 'brand')
      font = section('font', brand, 'brand.font')
      unknown_keys(font, %w[family], 'brand.font')
      colors = section('colors', brand, 'brand.colors')
      unknown_keys(colors, THEMES, 'brand.colors')
      Brand.new(
        name: text(brand['name'], 'brand.name', max: 80) || @project,
        logo: repo_path(brand['logo'], 'brand.logo'),
        logo_dark: repo_path(brand['logo_dark'], 'brand.logo_dark'),
        font_family: font_family(font['family']),
        light: theme(colors, 'light'),
        dark: theme(colors, 'dark')
      )
    end

    def font_family(value)
      return nil if value.nil?

      unless value.is_a?(String) && value.length <= 200 && value.match?(FONT_FAMILY)
        warn_field(dotted('brand.font.family'),
                   "expected letters, digits, spaces and , ' \" - only (at most 200 characters); using the system stack")
        return nil
      end
      value.strip
    end

    # A theme is used only when all three slots are valid hex: a declared
    # ground mixed with a neutral ink would produce nonsense.
    def theme(colors, name)
      prefix = "brand.colors.#{name}"
      slots = section(name, colors, prefix)
      return nil if slots.empty?

      unknown_keys(slots, SLOTS, prefix)
      bad = SLOTS.reject { |slot| slots[slot].is_a?(String) && slots[slot].match?(HEX) }
      if bad.empty?
        SLOTS.to_h { |slot| [ slot.to_sym, slots[slot].downcase ] }
      else
        bad.each { |slot| warn_field(dotted("#{prefix}.#{slot}"), "expected #rgb or #rrggbb (got #{slots[slot].inspect})") }
        warn_field(dotted(prefix), "theme not used; falling back to the #{name == 'light' ? 'neutral' : 'derived'} #{name} theme")
        nil
      end
    end

    # A repo-relative path: no absolute path, no `..` segment, and when it
    # already exists its realpath must stay inside the repo root (a symlink
    # pointing outside is refused).
    def repo_path(value, field, glob: false)
      return nil if value.nil?

      path = value.is_a?(String) ? value.strip : ''
      reason = path_problem(path, glob: glob)
      if reason
        warn_field(dotted(field), "#{reason}; ignored")
        return nil
      end
      path
    end

    def path_problem(path, glob:)
      return 'expected a repo-relative path' if path.empty? || path.match?(CONTROL)
      return 'must be relative to the repo root, not absolute' if path.start_with?('/', '~') || path.match?(/\A[A-Za-z]:[\\\/]/)
      return 'must not contain a .. segment' if path.split(%r{[\\/]}).include?('..')
      return nil if glob

      outside_root?(path) ? 'resolves outside the repo root' : nil
    end

    def outside_root?(path)
      full = File.join(@root, path)
      return false unless File.exist?(full)

      root = File.realpath(@root)
      real = File.realpath(full)
      real != root && !real.start_with?("#{root}/")
    end

    def read_imports(imports)
      unknown_keys(imports, IMPORT_FORMATS.keys, 'imports')
      Imports.new(coverage: import_list(imports['coverage'], 'coverage'),
                  test_results: import_list(imports['test_results'], 'test_results'))
    end

    def import_list(list, kind)
      field = "imports.#{kind}"
      return [] if list.nil?
      unless list.is_a?(Array)
        warn_field(dotted(field), 'expected a list; ignored')
        return []
      end

      list.each_with_index.filter_map { |item, index| import_item(item, kind, "#{field}[#{index}]") }
    end

    def import_item(item, kind, field)
      unless item.is_a?(Hash)
        warn_field(dotted(field), 'expected a mapping with path, format and label; ignored')
        return nil
      end

      unknown_keys(item, %w[path format label], field)
      format = import_format(item['format'], kind, field)
      path = item['path'].nil? ? missing(field, 'path') : repo_path(item['path'], "#{field}.path", glob: true)
      return nil unless format && path

      label = text(item['label'], "#{field}.label", max: 40) || format
      { path: path, format: format, label: label }
    end

    def import_format(value, kind, field)
      allowed = IMPORT_FORMATS.fetch(kind)
      return value if allowed.include?(value)

      warn_field(dotted("#{field}.format"),
                 "#{value.nil? ? 'required' : "unknown format #{value.inspect}"} (one of #{allowed.join(', ')}); import ignored")
      nil
    end

    def missing(field, key)
      warn_field(dotted("#{field}.#{key}"), 'required; import ignored')
      nil
    end

    def repo_copy_dir(value)
      return nil if value.nil?

      dir = repo_path(value, 'repo_copy.dir')
      return nil unless dir

      normalized = dir.split('/').reject { |seg| seg.empty? || seg == '.' }
      if normalized.empty? || normalized.first == '.git'
        warn_field(dotted('repo_copy.dir'), 'must name a directory inside the repo other than its root or .git; repo copy off')
        return nil
      end
      normalized.join('/')
    end

    def max_runs(value)
      return DEFAULT_MAX_RUNS if value.nil?
      return value if value.is_a?(Integer) && MAX_RUNS_RANGE.cover?(value)

      warn_field(dotted('history.max_runs'),
                 "expected an integer from #{MAX_RUNS_RANGE.min} to #{MAX_RUNS_RANGE.max} (got #{value.inspect}); using #{DEFAULT_MAX_RUNS}")
      DEFAULT_MAX_RUNS
    end
  end
end
