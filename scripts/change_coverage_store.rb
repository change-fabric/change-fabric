#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'time'
require_relative 'change_coverage_schema'
require_relative 'change_git_context'
require_relative 'change_report'

# Owns one QA coverage directory: `report-data.js`, the `.lock` beside it, and
# (through `page_writer:`) the page that renders it.
#
# Every write is read, merge, prune, rewrite, all under an exclusive flock, so
# two worktrees of one repo recording at once each land their run instead of
# one overwriting the other. The rewrite goes to a temp file renamed into place,
# so a reader never sees half a file. A full rewrite (not an append) is what
# makes retention and merge by id possible.
#
# The line format and ingest rule are ChangeCoverageSchema's; `parse` here is
# the reference reader for them.
class ChangeCoverageStore
  DATA_FILE = 'report-data.js'
  LOCK_FILE = '.lock'
  ROOT = File.join('.claude', 'cf', 'coverage')
  NO_PAGE = ->(_dir) { }

  Parsed = Data.define(:meta, :runs, :bad_lines)

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

  # The meta origin recorded in a directory's data file, or :none when there is
  # no data file or no meta line to compare against.
  def self.existing_origin(dir)
    path = File.join(dir, DATA_FILE)
    return :none unless File.file?(path)

    meta = parse(File.read(path, encoding: 'UTF-8')).meta
    meta ? meta['origin'] : :none
  rescue StandardError
    :none
  end

  # Splits data file text per the ingest rule. `bad_lines` are 1-based line
  # numbers of lines that are none of header, meta or a parseable run; blank
  # lines are not bad.
  def self.parse(text)
    meta = nil
    runs = []
    bad = []
    text.to_s.each_line.with_index(1) do |raw, number|
      line = raw.chomp
      next if line.strip.empty? || line == ChangeCoverageSchema::HEADER

      if (body = unwrap(line, ChangeCoverageSchema::META_PREFIX, ChangeCoverageSchema::META_SUFFIX))
        parsed = parse_json(body)
        parsed.is_a?(Hash) ? meta = parsed : bad << number
      elsif (body = unwrap(line, ChangeCoverageSchema::RUN_PREFIX, ChangeCoverageSchema::RUN_SUFFIX))
        run = parse_json(body)
        valid_run?(run) ? runs << run : bad << number
      else
        bad << number
      end
    end
    Parsed.new(meta:, runs:, bad_lines: bad)
  end

  def self.unwrap(line, prefix, suffix)
    return nil unless line.start_with?(prefix) && line.end_with?(suffix) && line.length >= prefix.length + suffix.length

    line[prefix.length...(line.length - suffix.length)]
  end

  def self.parse_json(body)
    JSON.parse(body)
  rescue JSON::ParserError
    nil
  end

  def self.valid_run?(run) = run.is_a?(Hash) && run['id'].is_a?(String) && !run['id'].empty?

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

  attr_reader :dir

  def initialize(dir, max_runs:, origin:, project:, page_writer: NO_PAGE)
    @dir = dir
    @max_runs = Integer(max_runs)
    @origin = ChangeGitContext.sanitize_url(origin)
    @project = ChangeReport.slug_for(project)
    @page_writer = page_writer
  end

  def data_path = File.join(@dir, DATA_FILE)

  # Merges `runs` into the file by id, prunes to max_runs, rewrites it, then
  # writes the page. Returns log lines (warnings first).
  def record(runs)
    incoming, lines = valid_incoming(runs)
    warnings = update { |existing| merge(existing, incoming) }
    lines + warnings + [ "recorded #{incoming.size} run(s) in #{data_path}" ]
  end

  # Merges every run in another data file (or a directory holding one, such
  # as a downloaded CI artifact) into this store. Its unreadable lines are
  # reported but never backed up; that file is not this store's.
  def merge_file(path)
    source = File.directory?(path) ? File.join(path, DATA_FILE) : path
    return [ "merge: #{source} not found" ] unless File.file?(source)

    parsed = self.class.parse(File.read(source, encoding: 'UTF-8'))
    lines = parsed.bad_lines.map { |number| "merge: #{source} line #{number} is not a coverage line; skipped" }
    lines + update { |existing| merge(existing, parsed.runs) } +
      [ "merged #{parsed.runs.size} run(s) from #{source} into #{data_path}" ]
  end

  # The runs currently on disk, sorted.
  def runs
    return [] unless File.file?(data_path)

    sort(self.class.parse(File.read(data_path, encoding: 'UTF-8')).runs)
  end

  # The full file body for `runs` under `meta`, one string per line.
  def write_lines(runs, meta: default_meta)
    [
      ChangeCoverageSchema::HEADER,
      "#{ChangeCoverageSchema::META_PREFIX}#{self.class.dump(meta)}#{ChangeCoverageSchema::META_SUFFIX}",
      *sort(runs).map { |run| "#{ChangeCoverageSchema::RUN_PREFIX}#{self.class.dump(run)}#{ChangeCoverageSchema::RUN_SUFFIX}" }
    ]
  end

  private

  def default_meta
    { 'format_version' => ChangeCoverageSchema::FORMAT_VERSION, 'project' => @project, 'origin' => @origin }
  end

  def valid_incoming(runs)
    valid, invalid = Array(runs).partition { |run| self.class.valid_run?(run) }
    [ valid, invalid.empty? ? [] : [ "skipped #{invalid.size} run(s) without an id" ] ]
  end

  # Runs the read-change-write cycle under the lock. The block gets the runs on
  # disk and returns the runs to write. Returns warning lines.
  def update
    FileUtils.mkdir_p(@dir)
    File.open(File.join(@dir, LOCK_FILE), File::RDWR | File::CREAT, 0o644) do |lock|
      lock.flock(File::LOCK_EX)
      parsed, lines = read_for_update
      write(yield(parsed.runs), meta_from(parsed.meta))
      @page_writer.call(@dir)
      lines
    end
  end

  # The file on disk, with any corrupt line reported and the original copied
  # aside before the clean rewrite replaces it.
  def read_for_update
    return [ self.class.parse(''), [] ] unless File.file?(data_path)

    text = File.read(data_path, encoding: 'UTF-8')
    parsed = self.class.parse(text)
    return [ parsed, [] ] if parsed.bad_lines.empty?

    backup = "#{data_path}.corrupt-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}"
    FileUtils.cp(data_path, backup)
    [ parsed, parsed.bad_lines.map { |number| "#{DATA_FILE} line #{number} is not a coverage line; original saved to #{backup}" } ]
  end

  # The directory keeps the origin of the repo that created it.
  def meta_from(existing)
    meta = default_meta
    meta['origin'] = existing['origin'] if existing.is_a?(Hash) && existing.key?('origin')
    meta
  end

  def merge(existing, incoming)
    by_id = existing.to_h { |run| [ run['id'], run ] }
    incoming.each { |run| by_id[run['id']] = run }
    sort(by_id.values).last(@max_runs)
  end

  def sort(runs) = runs.sort_by { |run| [ run['recorded_at'].to_s, run['id'].to_s ] }

  def write(runs, meta)
    temp = "#{data_path}.tmp-#{Process.pid}"
    File.write(temp, "#{write_lines(runs, meta:).join("\n")}\n", encoding: 'UTF-8')
    File.rename(temp, data_path)
  ensure
    FileUtils.rm_f(temp) if temp
  end
end
