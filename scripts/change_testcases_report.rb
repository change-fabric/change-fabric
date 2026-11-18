#!/usr/bin/env ruby
# frozen_string_literal: true

require 'cgi'
require 'digest'
require 'fileutils'
require 'json'
require 'rexml/document'
require_relative 'change_case_result'
require_relative 'change_testcases_evidence'
require_relative 'change_report'

# The testcases lane's own report, written into its run dir: report.html for a
# person and junit.xml for CI, both rendered from the run's case-result records
# and nothing else, plus one line per record appended to the project's history
# ledger.
#
# The ledger is JSONL outside the repo (LEDGER_ROOT/<project>/history.jsonl),
# so recording history never dirties the tree. report.html reads it to show the
# last HISTORY_RUNS results per case and to name what is newly failing (it
# passed the last time it ran) and what is flaky (passed after a failed
# attempt). A case skipped this run, and a case in the history that this run
# did not select, are listed on their own and never counted as failing.
class ChangeTestcasesReport
  LEDGER_ROOT = File.join(Dir.home, '.claude', 'cf', 'testcases')
  HISTORY_RUNS = 10
  THUMBNAILS = %w[failure.png final.png resumed-final.png].freeze

  # One ledger per project, repository and app, so two apps (or two repos)
  # sharing a project label never read each other's case history.
  def self.ledger_path(project, repo: nil, app: nil)
    scope = [ project, repo && "#{File.basename(repo)}-#{Digest::SHA256.hexdigest(File.expand_path(repo))[0, 8]}", app ]
    File.join(LEDGER_ROOT, *scope.compact.map { |part| ChangeReport.slug_for(part) }, 'history.jsonl')
  end

  attr_reader :records, :history

  def initialize(run_dir:, ledger:, records: nil)
    @run_dir = run_dir
    @ledger = ledger
    @records = records || read_records(File.join(run_dir, ChangeTestcasesEvidence::RESULTS_FILE))
    @history = read_records(ledger)
  end

  # Renders both files from the history as it stood before this run, then
  # appends this run to the ledger. Returns the paths written.
  def write
    html = File.join(@run_dir, 'report.html')
    junit = File.join(@run_dir, 'junit.xml')
    File.write(html, render_html)
    File.write(junit, render_junit)
    append_ledger
    { html: html, junit: junit, ledger: @ledger }
  end

  def render_junit
    doc = REXML::Document.new
    doc << REXML::XMLDecl.new('1.0', 'UTF-8')
    root = doc.add_element('testsuites', 'tests' => @records.size.to_s, 'failures' => @records.count(&:failure?).to_s)
    @records.group_by(&:suite).each do |suite, cases|
      root.add_element(junit_suite(suite, cases))
    end
    out = +''
    doc.write(output: out, indent: 2)
    "#{out}\n"
  end

  def render_html
    <<~HTML
      <!doctype html>
      <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Test cases #{h(run_id)}</title>
      <style>#{CSS}</style></head>
      <body>
      <h1>Test cases</h1>
      <p class="meta">Run #{h(run_id)}#{commit ? " at #{h(commit[0, 12])}" : ''}. #{summary}</p>
      #{attention_section}
      <h2>Cases</h2>
      <table><thead><tr><th>Case</th><th>Status</th><th>Persona</th><th>Duration</th><th>Attempts</th><th>Acceptance</th><th>Last #{HISTORY_RUNS} runs</th><th>Evidence</th></tr></thead>
      <tbody>
      #{executed.map { |record| case_row(record) }.join("\n")}
      </tbody></table>
      #{skipped_section}
      #{absent_section}
      </body></html>
    HTML
  end

  private

  CSS = <<~CSS.gsub(/\s+/, ' ').strip
    body { font: 14px/1.4 system-ui, sans-serif; margin: 24px; color: #1a1a1a; background: #fff; }
    table { border-collapse: collapse; width: 100%; margin-bottom: 24px; }
    th, td { border-bottom: 1px solid #ddd; padding: 6px 8px; text-align: left; vertical-align: top; }
    .meta { color: #555; }
    .pass { color: #116329; } .fail, .auth_interrupted, .partial_evidence { color: #b42318; font-weight: 600; }
    .skipped { color: #555; } .tag { font-size: 12px; padding: 1px 6px; border-radius: 8px; background: #f2f2f2; }
    .hist span { display: inline-block; width: 10px; height: 10px; margin-right: 2px; border-radius: 2px; background: #ccc; }
    .hist .h-pass { background: #2da44e; } .hist .h-fail { background: #cf222e; } .hist .h-skipped { background: #bbb; }
    img { max-width: 160px; border: 1px solid #ddd; }
    @media print { img { max-width: 120px; } }
  CSS

  def h(text) = CGI.escapeHTML(text.to_s)

  def read_records(path)
    return [] unless File.exist?(path)

    File.readlines(path).filter_map do |line|
      ChangeCaseResult.from_h(JSON.parse(line))
    rescue JSON::ParserError, ArgumentError
      nil
    end
  end

  def append_ledger
    FileUtils.mkdir_p(File.dirname(@ledger))
    File.open(@ledger, 'a') { |file| @records.each { |record| file.write("#{record.to_json}\n") } }
  end

  def run_id = @records.first&.run_id
  def commit = @records.first&.commit

  def executed = @records.reject(&:skipped?)

  def summary
    counts = @records.group_by(&:status).transform_values(&:size)
    ChangeCaseResult::STATUSES.filter_map { |status| "#{counts[status]} #{status}" if counts[status] }.join(', ')
  end

  def trend(record) = record.trend(@history)

  def attention_section
    newly = @records.select { |record| trend(record) == :newly_failing }
    flaky = @records.select(&:flaky?)
    return '' if newly.empty? && flaky.empty?

    items = newly.map { |record| "<li><span class=\"fail\">Newly failing</span> #{h(record.key)}</li>" } +
            flaky.map { |record| "<li><span class=\"tag\">Flaky</span> #{h(record.key)} (#{record.attempts.size} attempts)</li>" }
    "<h2>Needs attention</h2><ul>#{items.join}</ul>"
  end

  def case_row(record)
    cells = [ h(record.key), status_cell(record), h(record.persona), duration(record.duration_ms), record.attempts.size,
              h(record.acceptance_verdict || 'not graded'), history_cell(record), thumbnails(record) ]
    "<tr>#{cells.map { |cell| "<td>#{cell}</td>" }.join}</tr>"
  end

  def status_cell(record)
    note = { newly_failing: 'newly failing', no_history: 'no history', flaky: 'flaky' }[trend(record)]
    "<span class=\"#{record.status}\">#{h(record.status)}</span>#{note ? " <span class=\"tag\">#{note}</span>" : ''}"
  end

  def duration(ms) = ms ? format('%.1f s', ms / 1000.0) : '-'

  # The last HISTORY_RUNS results for this case, oldest first, ending with
  # this run.
  def history_cell(record)
    past = @history.select { |entry| entry.key == record.key }.last(HISTORY_RUNS - 1) + [ record ]
    marks = past.map do |entry|
      kind = history_kind(entry)
      "<span class=\"h-#{kind}\" title=\"#{h(entry.run_id)}: #{h(entry.status)}\"></span>"
    end
    "<span class=\"hist\">#{marks.join}</span>"
  end

  def history_kind(entry)
    return 'skipped' if entry.skipped?

    entry.failure? ? 'fail' : 'pass'
  end

  # The last attempt's screenshots, linked relative to the run dir so the page
  # works wherever the dir is copied.
  def thumbnails(record)
    dir = record.evidence_dir
    return '-' unless dir && Dir.exist?(dir)

    images = THUMBNAILS.select { |name| File.exist?(File.join(dir, name)) }
    return h(relative(dir)) if images.empty?

    images.map do |name|
      path = h(relative(File.join(dir, name)))
      "<a href=\"#{path}\"><img src=\"#{path}\" alt=\"#{h(record.key)} #{h(name)}\"></a>"
    end.join(' ')
  end

  def relative(path) = path.delete_prefix("#{@run_dir}/")

  def skipped_section
    skipped = @records.select(&:skipped?)
    return '' if skipped.empty?

    "<h2>Skipped this run</h2><ul>#{skipped.map { |record| "<li>#{h(record.key)}</li>" }.join}</ul>"
  end

  # Keys with history that this run did not select at all.
  def absent_section
    keys = @history.map(&:key).uniq - @records.map(&:key)
    return '' if keys.empty?

    "<h2>Not run this time</h2><ul>#{keys.map { |key| "<li>#{h(key)}</li>" }.join}</ul>"
  end

  def junit_suite(suite, cases)
    element = REXML::Element.new('testsuite')
    element.add_attributes('name' => suite, 'tests' => cases.size.to_s, 'failures' => cases.count(&:failure?).to_s,
                           'skipped' => cases.count(&:skipped?).to_s,
                           'time' => seconds(cases.sum { |record| record.duration_ms.to_i }))
    cases.each { |record| element.add_element(junit_case(record)) }
    element
  end

  def junit_case(record)
    element = REXML::Element.new('testcase')
    element.add_attributes('classname' => record.suite, 'name' => record.id, 'time' => seconds(record.duration_ms.to_i))
    if record.failure?
      failure = element.add_element('failure', 'message' => record.status, 'type' => record.status)
      failure.text = failure_text(record)
    elsif record.skipped?
      element.add_element('skipped')
    end
    element
  end

  def failure_text(record)
    last = record.attempts.last || {}
    outcome = last['outcome'] || last[:outcome]
    "#{record.key} #{record.status} after #{record.attempts.size} attempt(s)" \
      "#{outcome ? ", last attempt #{outcome}" : ''}; evidence: #{record.evidence_dir || 'none'}"
  end

  def seconds(ms) = format('%.3f', ms / 1000.0)
end
