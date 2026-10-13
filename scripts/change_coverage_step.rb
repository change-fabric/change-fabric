#!/usr/bin/env ruby
# frozen_string_literal: true

require 'time'
require_relative 'change_apps'
require_relative 'change_coverage'
require_relative 'change_coverage_brand'
require_relative 'change_coverage_import'
require_relative 'change_coverage_page'
require_relative 'change_coverage_store'
require_relative 'change_git_context'
require_relative 'change_report'
require_relative 'change_suite'
require_relative 'qa_report_config'

# The QA coverage step of a run, and the only thing `change_run.rb` talks to
# about coverage: the best-effort record after every deterministic sweep, and
# the `coverage build` and `coverage import` subcommands.
#
# `record_sweep` has the ChangeArtifactStep#finish contract: it returns log
# lines and rescues every StandardError into one of them, so nothing here can
# change a run's exit code, its findings or its gate record. The subcommands
# return `[exit_code, lines]` instead, because there the coverage record is the
# whole point of the invocation.
#
# Every store is keyed on the registry project (the root change_config.project),
# never a profile-overridden config.project, so one repo keeps one history
# whichever profile a sweep ran under.
class ChangeCoverageStep
  STAMP = '%Y%m%dT%H%M%SZ'
  LARGE_DATA_BYTES = 20 * 1024 * 1024

  # One identity per sweep: `{sweep_id, recorded_at}` from one clock reading
  # and the head sha. Every app of a multi-app sweep shares it.
  def self.sweep_ids(time, sha)
    short = sha.to_s.empty? ? 'nosha' : sha.to_s[0, 7]
    { sweep_id: "#{time.utc.strftime(STAMP)}-#{short}", recorded_at: time.utc }
  end

  # The ids of one app's record within a sweep: `<sweep_id>-run`, or
  # `<sweep_id>-run-<app slug>` when the sweep covers several apps.
  def self.run_ids(sweep, app: nil)
    suffix = app.to_s.empty? ? '' : "-#{ChangeReport.slug_for(app)}"
    sweep.merge(id: "#{sweep[:sweep_id]}-run#{suffix}")
  end

  # The registry project for a CHANGE.md, or nil when there is none or its
  # change_config: does not load. The store key and the brand default.
  def self.registry_project(change_md)
    File.file?(change_md.to_s) ? ChangeAppRegistry.load(change_md).project : nil
  rescue StandardError
    nil
  end

  # `repo_root` and `project` are what the subcommands record against;
  # record_sweep takes its own. `clock` and `env` are seams for tests.
  def initialize(repo_root: nil, project: nil, toolkit: nil, home: Dir.home, env: ENV, clock: -> { Time.now.utc })
    @repo_root = repo_root
    @project = project
    @toolkit = toolkit
    @home = home
    @env = env
    @clock = clock
  end

  # Records one app's sweep in the local store and rewrites its page. Returns
  # log lines; never raises.
  def record_sweep(registry_project:, repo_root:, config:, app:, lanes_ran:, findings:, instances:, ids:, toolkit:,
                   selection:, scope:)
    context = Context.new(self, repo_root, registry_project)
    run = ChangeCoverage.snapshot(
      config:, lanes_ran:, findings:, case_records: case_records(config, instances), suite_set: suite_set(config),
      selection:, git: context.git, ids:, toolkit:, repo: context.repo, imports: context.configured_imports,
      scope:, app:, warnings: context.warnings
    )
    store, lines = context.local_store
    context.warning_lines + lines + store.record([ run ]) + closing_lines(context, store)
  rescue StandardError => e
    [ "skipped (#{e.class}: #{e.message})" ]
  end

  # `coverage build`: rewrites the local store and its page, after merging in
  # each `merges` path (a data file or a directory holding one). `repo_copy`
  # also merges the store with the copy under qa_report.repo_copy.dir, by id
  # both ways. `out` writes to that directory instead of the store. Exit 1
  # when a `merges` path is missing or holds no coverage data, after writing
  # whatever else merged, so a mistyped CI artifact path is not a success.
  def build(repo_copy: false, merges: [], out: nil)
    context = Context.new(self, @repo_root, @project)
    return [ 2, [ 'set qa_report.repo_copy.dir in CHANGE.md' ] ] if repo_copy && context.repo_copy_dir.nil?

    store, lines = context.store_for(out)
    lines = context.no_change_md_lines + context.warning_lines + lines
    merged = merges.map { |path| merge_path(store, File.expand_path(path), lines) }
    lines.concat(rebuild(store))
    lines.concat(copy_to_repo(context, store)) if repo_copy
    [ merged.all? ? 0 : 1, lines + closing_lines(context, store) ]
  rescue StandardError => e
    [ 1, [ "build failed (#{e.class}: #{e.message})" ] ]
  end

  # `coverage import`: records one import-only run from CI result files.
  # `identity` (`sha`, `branch`, `pr`, `profile`, `app`) overrides what git
  # reports, which is what a detached CI checkout needs. Exit 0 when the run
  # was recorded, 1 when no file could be read, 2 on an unknown format.
  def import(files:, format:, label: nil, identity: {}, out: nil)
    format = format.to_s
    return [ 2, [ "unknown format #{format.inspect}; one of #{ChangeCoverageImport::FORMATS.join(', ')}" ] ] unless
      ChangeCoverageImport::FORMATS.include?(format)

    label = label.to_s.empty? ? format : label.to_s
    context = Context.new(self, @repo_root, @project, identity:)
    context.settings
    result = ChangeCoverageImport.read(paths: files.map { |file| context.import_path(file) }, format:, label:,
                                       repo_root: @repo_root, head_time: context.head_time)
    context.warnings.concat(result.warnings)
    lines = context.warning_lines
    return [ 1, lines + [ "#{label}: no #{format} file could be read; nothing recorded" ] ] unless result.summary

    run = ChangeCoverage.import_run(
      summaries: [ result.summary ], git: context.git, ids: import_ids(context, format, label),
      toolkit: @toolkit, repo: context.repo, profile: identity[:profile], app: identity[:app],
      warnings: context.warnings
    )
    store, store_lines = context.store_for(out)
    [ 0, lines + store_lines + store.record([ run ]) + closing_lines(context, store) ]
  rescue StandardError => e
    [ 1, [ "import failed (#{e.class}: #{e.message})" ] ]
  end

  attr_reader :home, :env

  def now = @clock.call

  private

  def case_records(config, instances)
    lane = instances.is_a?(Hash) ? instances['testcases'] : nil
    return [] unless lane.respond_to?(:case_records)

    lane.case_records(base_url: config.lane('testcases').base_url(config.boot.target_url))
  end

  # The suite files the testcases lane reads, or nil when it declares none.
  def suite_set(config)
    lane = config.lane('testcases')
    globs = Array(lane['suites']).map(&:to_s).reject(&:empty?)
    globs.empty? ? nil : ChangeSuiteSet.load(globs, lane.dir)
  end

  def import_ids(context, format, label)
    sweep = self.class.sweep_ids(now, context.git['sha'])
    sweep.merge(id: "#{sweep[:sweep_id]}-import-#{format}-#{ChangeReport.slug_for(label)}")
  end

  # Rewrites the data file and page with nothing new, so a build with no
  # merges still renders the current brand.
  def rebuild(store)
    store.record([]).reject { |line| line.start_with?('recorded 0 run(s)') } + [ "rebuilt #{store.dir}" ]
  end

  # Merges one `--merge` path into the store, appending its log lines to
  # `lines`. False when the path is missing or holds no coverage data.
  def merge_path(store, path, lines)
    source = File.directory?(path) ? File.join(path, ChangeCoverageStore::DATA_FILE) : path
    lines.concat(store.merge_file(source))
    return false unless File.file?(source)
    return true if coverage_data?(source)

    lines << "merge: #{source} holds no coverage data"
    false
  end

  def coverage_data?(path)
    parsed = ChangeCoverageStore.parse(File.read(path, encoding: 'UTF-8'))
    !parsed.meta.nil? || !parsed.runs.empty?
  end

  # Merges the store and the repo copy by id, both ways, so each ends up with
  # every run either had (retention applies to both). The copy is written in
  # place and never staged, committed, or given a .gitattributes entry. It
  # takes the store's lock rather than one of its own, so the directory holds
  # only the data file and the page; the two merges run one after the other,
  # never nested, so neither waits on a lock the other holds.
  def copy_to_repo(context, store)
    dir = File.join(context.repo_root, context.repo_copy_dir)
    copy = context.store_in(dir, lock_path: store.lock_path)
    lines = []
    lines.concat(store.merge_file(dir)) if File.file?(copy.data_path)
    lines.concat(copy.merge_file(store.data_path))
    lines + [ "repo copy: #{dir} (not staged; commit it yourself)" ] +
      QaReportConfig.gitattributes_lines(context.repo_root, context.repo_copy_dir)
  end

  # The page and data-size lines every write ends with.
  def closing_lines(context, store) = context.page_lines + size_lines(store)

  def size_lines(store)
    size = File.file?(store.data_path) ? File.size(store.data_path) : 0
    return [] if size <= LARGE_DATA_BYTES

    [ "warning: #{store.data_path} is #{size / (1024 * 1024)} MB; lower qa_report.history.max_runs to trim it" ]
  end

  # What one invocation resolves once: settings, git, origin, brand, and the
  # stores it writes, each with a page writer that never raises past the data
  # file.
  class Context
    attr_reader :repo_root, :warnings

    def initialize(step, repo_root, project, identity: {})
      @step = step
      @repo_root = File.expand_path(repo_root || Dir.pwd)
      @declared_project = project
      @identity = identity.transform_keys(&:to_sym)
      @warnings = []
      @page_lines = []
    end

    def change_md = File.join(@repo_root, 'CHANGE.md')

    def warning_lines = warned(@warnings)

    def project = @declared_project || File.basename(@repo_root)

    def no_change_md_lines
      File.file?(change_md) ? [] : [ "warning: no CHANGE.md at #{@repo_root}; project #{project}, neutral brand" ]
    end

    def settings
      @settings ||= QaReportConfig.load(@repo_root, project:).tap do |loaded|
        @warnings.concat(loaded.warnings)
      end
    end

    def repo_copy_dir = settings.repo_copy_dir

    def origin = @origin ||= ChangeGitContext.origin_url(@repo_root)

    def repo = { root: @repo_root, origin: origin }

    def head_time
      return @head_time if defined?(@head_time)

      @head_time = ChangeGitContext.head_commit_time(@repo_root)
    end

    def trunk = settings.trunk || ChangeGitContext.trunk_default(@repo_root)

    # ChangeGitContext's facts with the identity flags laid over them, plus
    # whether the branch is the trunk.
    def git
      @git ||= begin
        facts = ChangeGitContext.read(@repo_root, env: @step.env)
        facts = override(facts)
        facts.merge('trunk' => !facts['branch'].nil? && facts['branch'] == trunk)
      end
    end

    # The configured import globs, read now; nil when none were configured or
    # none matched.
    def configured_imports
      imports = settings.imports
      entries = imports.coverage + imports.test_results
      summaries = entries.filter_map do |entry|
        result = ChangeCoverageImport.read(paths: entry[:path], format: entry[:format], label: entry[:label],
                                           repo_root: @repo_root, head_time:)
        @warnings.concat(result.warnings)
        result.summary
      end
      summaries.empty? ? nil : summaries
    end

    # A CLI file argument as the importer should see it: relative to the repo
    # when inside it (so a committed record names no home path), else absolute.
    def import_path(file)
      absolute = File.expand_path(file)
      absolute.start_with?("#{@repo_root}/") ? absolute.delete_prefix("#{@repo_root}/") : absolute
    end

    # The local store under ~/.claude/cf/coverage, and any origin-mismatch line.
    def local_store
      dir, lines = ChangeCoverageStore.locate(project:, origin:, home: @step.home)
      [ store_in(dir), warned(lines) ]
    end

    def store_at(dir) = [ store_in(File.expand_path(dir)), [] ]

    # The `--out DIR` store when one was given, else the local store.
    def store_for(out) = out ? store_at(out) : local_store

    def store_in(dir, lock_path: nil)
      ChangeCoverageStore.new(dir, max_runs: settings.max_runs, origin:, project:, page_writer: page_writer,
                                   lock_path:)
    end

    # One line per page written, plus the brand's own warnings once.
    def page_lines
      brand_warnings = @brand ? warned(@brand.warnings) : []
      brand_warnings + @page_lines.uniq
    end

    private

    def warned(lines) = lines.map { |line| "warning: #{line}" }

    def brand = @brand ||= ChangeCoverageBrand.resolve(settings, repo_root: @repo_root)

    # The data file is already on disk when this runs, so a missing template
    # or a brand problem costs the page, never the record.
    def page_writer
      lambda do |dir|
        ChangeCoveragePage.write(dir, brand)
        @page_lines << "page: #{File.join(dir, ChangeCoveragePage::FILE)}"
      rescue StandardError => e
        @page_lines << "warning: page not written in #{dir} (#{e.class}: #{e.message})"
      end
    end

    def override(facts)
      sha = present(@identity[:sha])
      branch = present(@identity[:branch])
      pr = present(@identity[:pr])
      facts = facts.merge('sha' => sha, 'short_sha' => sha[0, 7]) if sha
      facts = facts.merge('branch' => branch) if branch
      facts = facts.merge('pr' => { 'number' => pr.to_i, 'url' => nil }) if pr
      facts
    end

    def present(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end
  end
end
