#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'set'
require 'time'
require_relative 'change_coverage_schema'
require_relative 'change_git_context'
require_relative 'change_report'

# Owns one QA coverage directory: `runs/<id>.json` (one immutable file per
# run), the generated `report-data.js` bundle, and (through `page_writer:`)
# the page that renders it.
#
# A write never reads or rewrites another run. Each run is written to a temp
# file and hard-linked to its final name, which fails rather than overwrites
# when the name is taken, so two worktrees recording at once each land their
# own file with no lock. A taken id retries as `<id>-2` up to `<id>-9`.
# Retention deletes the oldest files; the bundle is rebuilt from what is left,
# and a file that does not parse is skipped, so a crash mid-write is harmless.
class ChangeCoverageStore
  DATA_FILE = 'report-data.js'
  RUNS_DIR = 'runs'
  ROOT = File.join('.claude', 'cf', 'coverage')
  NO_PAGE = ->(_dir) { }
  MAX_SUFFIX = 9
  FULL_RUNS = 20

  # The directory for a project, keyed on the registry project slug. A
  # directory created by a repo with a different origin is not reused: the
  # caller gets `<slug>-<8 hex of SHA256(origin)>` and a warning line.
  def self.locate(project:, origin:, home: Dir.home)
    slug = ChangeReport.slug_for(project)
    base = File.join(home, ROOT, slug)
    origin = ChangeGitContext.sanitize_url(origin)
    existing = existing_origin(base)
    return [ base, [] ] if existing == :none || existing == origin

    suffixed = "#{base}-#{Digest::SHA256.hexdigest(origin.to_s)[0, 8]}"
    [ suffixed, [ "#{base} belongs to origin #{existing.inspect}, not #{origin.inspect}; using #{suffixed}" ] ]
  end

  def self.dir_for(project:, origin:, home: Dir.home) = locate(project:, origin:, home:).first

  # The meta origin recorded in a directory's bundle, or :none when there is
  # no bundle or no meta to compare against.
  def self.existing_origin(dir)
    meta = read_bundle(File.join(dir, DATA_FILE))&.fetch('meta', nil)
    meta.is_a?(Hash) && meta.key?('origin') ? meta['origin'] : :none
  rescue StandardError
    :none
  end

  # Writes one run as `runs/<id>.json` and returns the path. Never overwrites:
  # a taken name retries with `-2` to `-9`, then raises Errno::EEXIST. The
  # `id` inside the JSON keeps the base id; the basename is the id of record.
  def self.write_run(dir, run)
    raise ArgumentError, 'run needs a non-empty string id' unless ChangeCoverageSchema.valid_run?(run)

    runs = File.join(dir, RUNS_DIR)
    FileUtils.mkdir_p(runs)
    base = run.fetch('id')
    tmp = File.join(runs, ".#{base}.#{Process.pid}.#{rand(1 << 32)}.tmp")
    File.write(tmp, JSON.generate(run), encoding: 'UTF-8')
    (1..MAX_SUFFIX).each do |n|
      dest = File.join(runs, "#{n == 1 ? base : "#{base}-#{n}"}.json")
      return dest if place(tmp, dest)
    end
    raise Errno::EEXIST, "run id collision past -#{MAX_SUFFIX}: #{base}"
  ensure
    FileUtils.rm_f(tmp) if tmp
  end

  # True when `dest` was created from `tmp`, false when the name is taken.
  # A hard link appears with its full contents at once; a file system that
  # refuses links gets an exclusive create and a plain write instead.
  def self.place(tmp, dest)
    File.link(tmp, dest)
    true
  rescue Errno::EEXIST
    false
  rescue Errno::EPERM, Errno::EXDEV, Errno::ENOTSUP, NotImplementedError
    begin
      File.open(dest, File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.write(File.read(tmp)) }
      true
    rescue Errno::EEXIST
      false
    end
  end
  private_class_method :place

  # Every readable run in `dir`, sorted by `recorded_at` then file id. A file
  # that does not parse or is not a valid run is skipped with a stderr line.
  # Each run's `id` is set to its file basename.
  def self.list(dir, warn_to: $stderr)
    Dir.glob(File.join(dir, RUNS_DIR, '*.json')).filter_map do |path|
      run = JSON.parse(File.read(path, encoding: 'UTF-8'))
      raise JSON::ParserError, 'not a run' unless ChangeCoverageSchema.valid_run?(run)

      run.merge('id' => File.basename(path, '.json'))
    rescue JSON::ParserError, EncodingError, ArgumentError, SystemCallError => e
      warn_to&.puts("coverage: skipped #{path}: #{e.message.lines.first&.strip}")
      nil
    end.then { |runs| sort(runs) }
  end

  def self.sort(runs) = runs.sort_by { |run| [ run['recorded_at'].to_s, run['id'].to_s ] }

  # Deletes the oldest run files beyond `max_runs`; 0 deletes them all.
  # Returns the deleted paths.
  def self.prune(dir, max_runs)
    max_runs = Integer(max_runs)
    runs = list(dir, warn_to: nil)
    doomed = max_runs.positive? ? runs[0...[ runs.size - max_runs, 0 ].max] : runs
    doomed.map { |run| File.join(dir, RUNS_DIR, "#{run['id']}.json").tap { |path| FileUtils.rm_f(path) } }
  end

  # A run with its counts but without its per-case lists.
  def self.summarize(run)
    out = run.merge('summary' => true)
    out['cases'] = run['cases'].except('items') if run['cases'].is_a?(Hash)
    if run.dig('imports', 'test_results').is_a?(Array)
      out['imports'] = run['imports'].merge('test_results' => run['imports']['test_results'].map { |r| r.except('items') })
    end
    out
  end

  # The bundle object: the newest `full` runs as written, older ones summarized.
  def self.bundle(runs, meta:, full: FULL_RUNS)
    sorted = sort(runs)
    cut = [ sorted.size - full, 0 ].max
    { 'meta' => meta.merge('format_version' => ChangeCoverageSchema::FORMAT_VERSION),
      'runs' => sorted.each_with_index.map { |run, i| i < cut ? summarize(run) : run } }
  end

  # JSON a classic script can carry: `</`, U+2028 and U+2029 escaped. A json
  # gem without `script_safe` (older than 2.7) silently ignores the option, so
  # the result is checked once and escaped by hand when it was ignored.
  SCRIPT_SAFE = JSON.generate('</', script_safe: true) != '"</"'

  def self.dump(obj)
    json = JSON.generate(obj, script_safe: true)
    SCRIPT_SAFE ? json : escape_for_script(json)
  end

  # The manual fallback. `<` never appears in JSON outside a string, so
  # escaping every `</` cannot change structure.
  def self.escape_for_script(json)
    json.gsub('</', '<\\/').gsub("\u2028", '\\u2028').gsub("\u2029", '\\u2029')
  end

  def self.bundle_text(bundle) = "#{ChangeCoverageSchema::BUNDLE_PREFIX}#{dump(bundle)}#{ChangeCoverageSchema::BUNDLE_SUFFIX}\n"

  # The parsed bundle at `path`, or nil when it is missing or not a bundle.
  def self.read_bundle(path)
    return nil unless File.file?(path)

    text = File.read(path, encoding: 'UTF-8').strip
    prefix = ChangeCoverageSchema::BUNDLE_PREFIX
    suffix = ChangeCoverageSchema::BUNDLE_SUFFIX
    return nil unless text.start_with?(prefix) && text.end_with?(suffix)

    parsed = JSON.parse(text[prefix.length...(text.length - suffix.length)])
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError, EncodingError
    nil
  end

  # Runs recorded in a format version 1 `report-data.js` (one
  # `window.CF_QA_COVERAGE.runs.push(...)` line per run), for the one-time
  # split into run files.
  def self.legacy_runs(text)
    text.to_s.each_line.filter_map do |line|
      next unless line.valid_encoding?

      line = line.strip
      next unless line.start_with?(LEGACY_RUN_PREFIX) && line.end_with?(');')

      run = JSON.parse(line[LEGACY_RUN_PREFIX.length...-2])
      ChangeCoverageSchema.valid_run?(run) ? run : nil
    rescue JSON::ParserError
      nil
    end
  end
  LEGACY_RUN_PREFIX = 'window.CF_QA_COVERAGE.runs.push('

  attr_reader :dir

  def initialize(dir, max_runs:, origin:, project:, page_writer: NO_PAGE)
    @dir = dir
    @max_runs = Integer(max_runs)
    @origin = ChangeGitContext.sanitize_url(origin)
    @project = ChangeReport.slug_for(project)
    @page_writer = page_writer
  end

  def data_path = File.join(@dir, DATA_FILE)

  # Writes each run as its own file, prunes, rebuilds the bundle and the page.
  # max_runs 0 records nothing. Returns log lines.
  def record(runs)
    valid, invalid = Array(runs).partition { |run| ChangeCoverageSchema.valid_run?(run) }
    lines = invalid.empty? ? [] : [ "skipped #{invalid.size} run(s) without an id" ]
    return lines + [ 'qa_report history max_runs is 0; nothing recorded' ] if @max_runs.zero?

    migrate_legacy
    valid.each { |run| self.class.write_run(@dir, run) }
    build
    lines + [ "recorded #{valid.size} run(s) in #{File.join(@dir, RUNS_DIR)}" ]
  end

  # Copies every run file from another store directory (such as a downloaded
  # CI artifact) into this one, skipping ids already present, then rebuilds.
  def merge_file(path)
    source = File.basename(path) == DATA_FILE ? File.dirname(path) : path
    return [ "merge: #{File.join(source, RUNS_DIR)} not found" ] unless File.directory?(File.join(source, RUNS_DIR))

    have = runs.to_set { |run| run['id'] }
    incoming = self.class.list(source).reject { |run| have.include?(run['id']) }
    incoming.each { |run| self.class.write_run(@dir, run) }
    build
    [ "merged #{incoming.size} run(s) from #{source} into #{@dir}" ]
  end

  def runs = self.class.list(@dir)

  # Prunes to max_runs and regenerates report-data.js and the page.
  def build
    FileUtils.mkdir_p(@dir)
    self.class.prune(@dir, @max_runs)
    meta = { 'project' => @project, 'origin' => keep_origin }
    temp = "#{data_path}.tmp-#{Process.pid}"
    File.write(temp, self.class.bundle_text(self.class.bundle(runs, meta:)), encoding: 'UTF-8')
    File.rename(temp, data_path)
    @page_writer.call(@dir)
  ensure
    FileUtils.rm_f(temp) if temp
  end

  private

  # The directory keeps the origin of the repo that created it.
  def keep_origin
    existing = self.class.existing_origin(@dir)
    existing == :none ? @origin : existing
  end

  # Splits a format version 1 report-data.js into run files, once: only while
  # runs/ is empty.
  def migrate_legacy
    return unless File.file?(data_path)
    return if Dir.exist?(File.join(@dir, RUNS_DIR)) && !Dir.empty?(File.join(@dir, RUNS_DIR))

    text = File.read(data_path, encoding: 'UTF-8')
    return unless text.include?('"format_version":1')

    self.class.legacy_runs(text).each { |run| self.class.write_run(@dir, run) }
  end
end
