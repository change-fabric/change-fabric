#!/usr/bin/env ruby
# frozen_string_literal: true

require 'csv'
require 'time'
require 'fileutils'

# Renders a run's findings as a CSV and a Markdown report, written as a pair to
# the user's Desktop. The two share a base name so a run's machine-readable and
# readable forms stay together.
#
# No-clobber by design: the base name carries a UTC timestamp to the second and
# the run scope, so repeated runs accumulate a history on the Desktop rather than
# overwriting the last one. The CSV is the shareable data (one row per finding,
# stable column order); the Markdown is the at-a-glance read (a per-lane summary
# table then the failing findings first).
class ChangeReport
  DESKTOP = File.join(Dir.home, 'Desktop')

  # `app` (0.4.0) is the registry key of one app in a monorepo sweep, omitted
  # in single-app mode so an existing repo's report filenames are unchanged
  # byte for byte. Naming always comes from the root project plus the
  # registry key, never an app file's own `project:`, so two app files that
  # happen to share a `project:` value can never collide on disk.
  # `manifest` is the run's inputs: the digest-pinned image every container ran
  # from, the vendored scanner version, a digest of the resolved config, and
  # the toolkit that drove it. A report used to name only its verdict, which
  # made a disagreement between two reports unresolvable: nothing recorded what
  # either one had actually been run against. The same mapping is stored in the
  # gate record, so a recorded pass can be traced back to the exact inputs that
  # produced it rather than trusted on the strength of the word "pass".
  def initialize(project:, scope:, findings:, app: nil, meta: {}, sections: [], manifest: {})
    @project = project.to_s
    @scope = scope.to_s
    @findings = findings
    @app = app
    @meta = meta
    @manifest = manifest || {}
    @sections = Array(sections).compact
    @stamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
  end

  # Writes both files and returns their paths so the caller can name them in the
  # run summary and the gate record.
  def write
    FileUtils.mkdir_p(DESKTOP)
    csv = csv_path
    md = md_path
    File.write(csv, render_csv)
    File.write(md, render_markdown(File.basename(csv)))
    { csv: csv, markdown: md }
  end

  def base_name = "change-#{slug(@project)}#{@app ? "-#{slug(@app)}" : ''}-#{@scope}-#{@stamp}"

  # A small Markdown index over a multi-app sweep's own per-app report pairs:
  # one row per app, so the roll-up is the single artifact a human opens first
  # rather than having to compare each app's report by hand. Never a CSV: a
  # combined findings CSV would mix rows whose `target` column is only
  # meaningful within one app's own base url, and would change the stable
  # column order the per-app CSV already promises.
  def self.rollup(project:, scope:, rows:)
    FileUtils.mkdir_p(DESKTOP)
    stamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
    path = File.join(DESKTOP, "change-#{slug_for(project)}-sweep-#{stamp}.md")
    lines = [
      "# Change-fabric sweep: #{project}", '', "Scope: #{scope}. Generated #{Time.now.utc.iso8601}.", '',
      '| App | Result | Failing findings | Report |', '| --- | --- | --- | --- |'
    ]
    rows.each { |row| lines << "| #{row[:app]} | #{row[:passed] ? 'PASS' : 'FAIL'} | #{row[:failing]} | #{row[:report]} |" }
    File.write(path, "#{lines.join("\n")}\n")
    { markdown: path }
  end

  def self.slug_for(text)
    cleaned = text.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/-+/, '-').gsub(/\A-|-\z/, '')
    cleaned.empty? ? 'project' : cleaned
  end

  private

  def csv_path = File.join(DESKTOP, "#{base_name}.csv")
  def md_path = File.join(DESKTOP, "#{base_name}.md")

  def slug(text) = self.class.slug_for(text)

  def render_csv
    CSV.generate do |out|
      out << Findings::HEADER
      @findings.rows.each { |row| out << row }
    end
  end

  def render_markdown(csv_name)
    lines = []
    lines << "# Change-fabric report: #{@project}"
    lines << ''
    lines << "Scope: #{@scope}. Generated #{Time.now.utc.iso8601}. Data: #{csv_name}."
    lines << ''
    lines.concat(meta_lines)
    lines.concat(manifest_lines)
    lines.concat(summary_table)
    lines << ''
    @sections.each do |section|
      lines << section.to_s
      lines << ''
    end
    lines.concat(findings_section)
    "#{lines.join("\n")}\n"
  end

  def meta_lines
    return [] if @meta.empty?

    rows = @meta.map { |key, value| "- #{key}: #{value}" }
    [ '## Run', '', *rows, '' ]
  end

  # Rendered as a table rather than a list: a manifest is read by comparing one
  # run's row against another's, and a table is what makes two of them diffable
  # by eye.
  def manifest_lines
    return [] if @manifest.empty?

    rows = @manifest.map { |key, value| "| #{escape(key)} | #{escape(value)} |" }
    [ '## Run manifest', '', '| Input | Value |', '| --- | --- |', *rows, '' ]
  end

  def summary_table
    status = @findings.lane_status
    lines = [ '## Lane results', '', '| Lane | Result | Findings |', '| --- | --- | --- |' ]
    if status.empty?
      lines << '| (none) | - | 0 |'
    else
      status.each do |lane, result|
        count = @findings.count { |finding| finding.lane == lane }
        lines << "| #{lane} | #{result.upcase} | #{count} |"
      end
    end
    lines
  end

  def findings_section
    return [ '## Findings', '', 'No findings recorded.' ] if @findings.empty?

    lines = [ '## Findings', '', '| Lane | Status | Severity | Target | Check | Location | Detail | Attempts |',
              '| --- | --- | --- | --- | --- | --- | --- | --- |' ]
    @findings.sort_by { |finding| sort_key(finding) }.each { |finding| lines << finding_row(finding) }
    lines
  end

  # A total order over the rendered row, not just "failures first". The key used
  # to be the single fail?/not-fail bit, which leaves every finding sharing that
  # bit unordered relative to its peers: Ruby's sort_by is not stable, so the
  # same run's findings could render in a different order every time and a diff
  # between two reports of identical inputs was full of moved lines. Extending
  # the key through every column a row displays makes two equal keys mean two
  # identical rows, which are indistinguishable however they land.
  def sort_key(finding)
    [ finding.fail? ? 0 : 1, finding.lane, finding.status, finding.severity, finding.target,
      finding.check, finding.location, finding.detail, finding.help ]
  end

  # `attempts` renders as a plain count, with the flaky verdict called out
  # beside it: a pass that took three tries is a different fact from a pass
  # that took one, and burying that in the CSV alone lets a re-run-until-green
  # habit look like a clean report.
  def finding_row(finding)
    cells = [ finding.lane, finding.status.upcase, finding.severity, finding.target,
              finding.check, finding.location, finding.detail, attempts_cell(finding) ]
    "| #{cells.map { |cell| escape(cell) }.join(' | ')} |"
  end

  def attempts_cell(finding) = finding.flaky ? "#{finding.attempts} (flaky)" : finding.attempts.to_s

  # Keep a finding's free text from breaking the Markdown table: pipes escaped,
  # newlines flattened.
  def escape(cell) = cell.to_s.gsub('|', '\\|').gsub(/\s*\n\s*/, ' ')
end
