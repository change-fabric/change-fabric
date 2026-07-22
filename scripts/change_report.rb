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

  def initialize(project:, scope:, findings:, meta: {}, sections: [])
    @project = project.to_s
    @scope = scope.to_s
    @findings = findings
    @meta = meta
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

  def base_name = "change-#{slug(@project)}-#{@scope}-#{@stamp}"

  private

  def csv_path = File.join(DESKTOP, "#{base_name}.csv")
  def md_path = File.join(DESKTOP, "#{base_name}.md")

  def slug(text)
    cleaned = text.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/-+/, '-').gsub(/\A-|-\z/, '')
    cleaned.empty? ? 'project' : cleaned
  end

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

    ordered = @findings.sort_by { |finding| finding.fail? ? 0 : 1 }
    lines = [ '## Findings', '', '| Lane | Status | Severity | Target | Check | Location | Detail |',
              '| --- | --- | --- | --- | --- | --- | --- |' ]
    ordered.each { |finding| lines << finding_row(finding) }
    lines
  end

  def finding_row(finding)
    cells = [ finding.lane, finding.status.upcase, finding.severity, finding.target,
              finding.check, finding.location, finding.detail ]
    "| #{cells.map { |cell| escape(cell) }.join(' | ')} |"
  end

  # Keep a finding's free text from breaking the Markdown table: pipes escaped,
  # newlines flattened.
  def escape(cell) = cell.to_s.gsub('|', '\\|').gsub(/\s*\n\s*/, ' ')
end
