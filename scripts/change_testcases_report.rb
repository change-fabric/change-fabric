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
require_relative 'change_flake_triage'

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
#
# (suite_version 8) A case can also end `warn` (every check passed, but only after
# a re-read agreed with itself: drift) or `blocked_precondition` (it could not be
# verified: a login or a record it needed was not there). Neither is
# a failure and neither is a pass, so the page names them in their own sections:
# "Not verified" first when there is anything in it, then the warnings, the
# figures every case read with where and when, and the basis each verdict rests on.
class ChangeTestcasesReport
  LEDGER_ROOT = File.join(Dir.home, '.claude', 'cf', 'testcases')
  HISTORY_RUNS = 10
  THUMBNAILS = %w[failure.png final.png resumed-final.png].freeze

  # One ledger per project, repository and app, so two apps (or two repos)
  # sharing a project label never read each other's case history. Each part
  # past the project carries a digest of its exact value, so names that slug
  # alike (`web_api`, `web-api`) still get their own ledger.
  def self.ledger_path(project, repo: nil, app: nil)
    scope = [ ChangeReport.slug_for(project) ]
    scope << distinct_part(File.basename(repo), File.expand_path(repo)) if repo
    scope << distinct_part(app, app) if app
    File.join(LEDGER_ROOT, *scope, 'history.jsonl')
  end

  def self.distinct_part(label, identity)
    "#{ChangeReport.slug_for(label)}-#{Digest::SHA256.hexdigest(identity.to_s)[0, 8]}"
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
    flake = write_flake_proposals
    html = write_html
    junit = File.join(@run_dir, 'junit.xml')
    File.write(junit, render_junit)
    append_ledger
    { html: html, junit: junit, ledger: @ledger, flake_proposals: flake }
  end

  # report.html alone, from the history as read before this run was
  # appended, so a later export can refresh it without a second ledger entry.
  def write_html
    File.join(@run_dir, 'report.html').tap { |path| File.write(path, render_html) }
  end

  # flake-proposals.md and .json in the run dir, from the history plus this
  # run, only when some case is flipping. Proposals never change a suite or a
  # verdict, so a failure here is dropped rather than blocking the ledger.
  def write_flake_proposals
    triage = ChangeFlakeTriage.new(@history + @records)
    return triage.write(@run_dir)[:markdown] if triage.proposals.any?

    # A rerun into the same dir must not leave an earlier run's proposals behind.
    [ ChangeFlakeTriage::MARKDOWN_FILE, ChangeFlakeTriage::JSON_FILE ].each { |name| FileUtils.rm_f(File.join(@run_dir, name)) }
    nil
  rescue StandardError
    nil
  end

  def render_junit
    doc = REXML::Document.new
    doc << REXML::XMLDecl.new('1.0', 'UTF-8')
    root = doc.add_element('testsuites', 'tests' => @records.size.to_s, 'failures' => @records.count(&:failure?).to_s,
                           'skipped' => @records.count { |record| record.skipped? || record.blocked? }.to_s)
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
      #{not_verified_section}
      #{attention_section}
      #{flake_section}
      #{suggestion_section}
      #{visual_section}
      <h2>Cases</h2>
      <table><thead><tr><th>Case</th><th>Status</th><th>Persona</th><th>Duration</th><th>Attempts</th><th>Acceptance</th><th>Quarantine</th><th>Last #{HISTORY_RUNS} runs</th><th>Evidence</th><th>Video</th></tr></thead>
      <tbody>
      #{executed.map { |record| case_row(record) }.join("\n")}
      </tbody></table>
      #{warnings_section}
      #{figures_section}
      #{basis_section}
      #{skipped_section}
      #{absent_section}
      #{export_section}
      <script>document.body.setAttribute("data-cf-ready", "1");</script>
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
    .warn { color: #8a5a00; font-weight: 600; } .blocked_precondition { color: #5b3f9e; font-weight: 600; }
    .skipped { color: #555; } .tag { font-size: 12px; padding: 1px 6px; border-radius: 8px; background: #f2f2f2; }
    .hist span { display: inline-block; width: 10px; height: 10px; margin-right: 2px; border-radius: 2px; background: #ccc; }
    .hist .h-pass { background: #2da44e; } .hist .h-fail { background: #cf222e; } .hist .h-skipped { background: #bbb; }
    .hist .h-warn { background: #bf8700; } .hist .h-blocked { background: #8250df; }
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
    list = ChangeCaseResult::STATUSES.filter_map { |status| "#{counts[status]} #{status}" if counts[status] }.join(', ')
    "#{list}. Run status: #{ChangeCaseResult.worst_status(@records)}"
  end

  # The cases that could not be verified, before anything else: a run with
  # unverified cases is not the same as a run where everything passed, and the
  # reader should not have to scroll to learn that.
  def not_verified_section
    blocked = @records.select(&:blocked?)
    return '' if blocked.empty?

    items = blocked.map do |record|
      "<li><span class=\"blocked_precondition\">Not verified</span> #{h(record.key)}: #{h(record.blocked_reason || 'blocked')}</li>"
    end
    "<h2>Not verified</h2><p>These cases could not be checked. They count as neither passed nor failed.</p><ul>#{items.join}</ul>"
  end

  # Each drift: the relation passed only after a re-read. Both value sets and
  # when each was read, so the reader can judge whether the figure was merely
  # slow to update or the page is flapping.
  def warnings_section
    drifts = @records.flat_map { |record| record.relations.select { |relation| relation['drift'] }.map { |relation| [ record, relation ] } }
    return '' if drifts.empty?

    rows = drifts.map do |record, relation|
      "<tr><td>#{h(record.key)}</td><td>#{h(relation['label'])}</td><td>#{reads_cell(relation['first_reads'])}</td>" \
        "<td>#{reads_cell(relation['reads'])}</td></tr>"
    end
    "<h2>Warnings</h2><p>These relations disagreed on the first read and agreed on the re-read (drift).</p>" \
      "<table><thead><tr><th>Case</th><th>Relation</th><th>First read</th><th>Re-read</th></tr></thead><tbody>#{rows.join}</tbody></table>"
  end

  def reads_cell(reads)
    Array(reads).map do |read|
      "#{h(read['var'])} = #{h(JSON.generate(read['value']))} <span class=\"tag\">#{h(read['read_at'])}</span>"
    end.join('<br>')
  end

  # Every figure a case read: the value, where it was read, when, the freshness
  # text on the page at the time, and where it was read from.
  def figures_section
    rows = @records.flat_map { |record| record.vars.map { |figure| [ record, figure ] } }
    return '' if rows.empty?

    body = rows.map do |record, figure|
      cells = [ record.key, figure['var'], JSON.generate(figure['value']), figure['url'], figure['read_at'], figure['freshness'],
                figure['source'] ]
      "<tr>#{cells.map { |cell| "<td>#{h(cell)}</td>" }.join}</tr>"
    end
    "<h2>Captured figures</h2><table><thead><tr><th>Case</th><th>Var</th><th>Value</th><th>URL</th><th>Read at</th>" \
      "<th>Freshness</th><th>Source</th></tr></thead><tbody>#{body.join}</tbody></table>"
  end

  # Per case, which measured reads and relations decided the verdict.
  def basis_section
    items = @records.filter_map do |record|
      next if record.vars.empty? && record.relations.empty?

      reads = record.vars.map { |figure| figure['var'] }.uniq.join(', ')
      relations = record.relations.map { |relation| "#{h(relation['label'])}: #{h(relation['status'])}" }.join('; ')
      "<li>#{h(record.key)} (#{h(record.status)}): reads #{h(reads.empty? ? 'none' : reads)}#{relations.empty? ? '' : "; relations #{relations}"}</li>"
    end
    return '' if items.empty?

    "<h2>Verification basis</h2><ul>#{items.join}</ul>"
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

  def flake_section
    return '' unless File.exist?(File.join(@run_dir, ChangeFlakeTriage::MARKDOWN_FILE))

    "<h2>Flake proposals</h2><p>Quarantine proposals for flipping cases: <a href=\"#{ChangeFlakeTriage::MARKDOWN_FILE}\">" \
      "#{ChangeFlakeTriage::MARKDOWN_FILE}</a> (<a href=\"#{ChangeFlakeTriage::JSON_FILE}\">json</a>). No suite was edited.</p>"
  end

  # Suggest-only: what a human could change a failed selector to. The case is
  # still failed; nothing here is applied. Values were redacted when recorded
  # and are escaped again here.
  def suggestion_section
    rows = @records.flat_map do |record|
      record.selector_suggestions.map { |entry| suggestion_item(record, entry) }
    end
    return '' if rows.empty?

    "<h2>Selector suggestions</h2><p>Top candidates for a human to review. The case still fails; " \
      "nothing was changed.</p><ul>#{rows.join}</ul>"
  end

  def suggestion_item(record, entry)
    candidates = Array(entry['candidates']).grep(Hash).map do |candidate|
      "<li><code>#{h(candidate['selector'])}</code> by #{h(candidate['by'])}, #{h(candidate['matches'])} match(es)</li>"
    end
    shown = candidates.empty? ? '<p>No candidate found.</p>' : "<ol>#{candidates.join}</ol>"
    note = entry['note'] ? "<p>#{h(entry['note'])}</p>" : ''
    "<li>#{h(record.key)} step #{h(entry['step'].to_i + 1)}: <code>#{h(entry['failed'])}</code>#{shown}#{note}</li>"
  end

  # expect_visual verdicts with their images. A blocked result carries the
  # command that would accept the candidate; only a person runs it.
  def visual_section
    rows = @records.flat_map { |record| record.visual_results.map { |entry| visual_item(record, entry) } }
    return '' if rows.empty?

    "<h2>Visual baselines</h2><p>A missing baseline blocks the case; nothing is accepted automatically.</p><ul>#{rows.join}</ul>"
  end

  def visual_item(record, entry)
    files = entry['files'].is_a?(Hash) ? entry['files'] : { 'actual' => entry['candidate'] }.compact
    images = record.evidence_dir ? files.map { |label, name| visual_image(record, label, name) } : []
    command = entry['promote'] ? "<p>Accept the candidate: <code>#{h(entry['promote'])}</code></p>" : ''
    "<li>#{h(record.key)} #{h(entry['name'])} at #{h(entry['viewport'])}: <span class=\"#{entry['status'] == 'pass' ? 'pass' : 'fail'}\">" \
      "#{h(entry['status'])}</span> #{h(entry['note'])}#{images.join}#{command}</li>"
  end

  def visual_image(record, label, name)
    path = h(relative(File.join(record.evidence_dir, name.to_s)))
    "<figure><a href=\"#{path}\"><img src=\"#{path}\" alt=\"#{h(label)}\"></a><figcaption>#{h(label)}</figcaption></figure>"
  end

  def case_row(record)
    cells = [ h(record.key), status_cell(record), h(record.persona), duration(record.duration_ms), record.attempts.size,
              h(record.acceptance_verdict || 'not graded'), quarantine_cell(record), history_cell(record), thumbnails(record), video_cell(record) ]
    "<tr>#{cells.map { |cell| "<td>#{cell}</td>" }.join}</tr>"
  end

  def status_cell(record)
    note = { newly_failing: 'newly failing', no_history: 'no history', flaky: 'flaky' }[trend(record)]
    "<span class=\"#{record.status}\">#{h(record.status)}</span>#{note ? " <span class=\"tag\">#{note}</span>" : ''}"
  end

  def quarantine_cell(record)
    return '-' unless record.quarantined?

    "<span class=\"tag\">quarantined</span> #{h(record.quarantine_reason)}"
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
    return 'warn' if entry.warn?
    return 'blocked' if entry.blocked?

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

  EXPORTS_FILE = 'exports.json'

  # What --export produced, from the run dir's exports.json. An export that
  # failed is named here and nowhere near a case's verdict.
  # Read fresh on each render, so a refresh after a later export shows it.
  def exports
    path = File.join(@run_dir, EXPORTS_FILE)
    File.exist?(path) ? JSON.parse(File.read(path)) : {}
  rescue JSON::ParserError
    {}
  end

  def video_cell(record)
    entry = exports.dig('video', record.key)
    return '-' unless entry
    return "<span class=\"tag\">export failed</span> #{h(entry['reason'])}" unless entry['status'] == 'ok'

    "<a href=\"#{h(relative(entry['path']))}\">mp4</a>"
  end

  def export_section
    failed = exports.flat_map do |kind, entries|
      entries.is_a?(Hash) ? entries.reject { |_key, entry| entry['status'] == 'ok' }.map { |key, entry| [ kind, key, entry ] } : []
    end
    return '' if failed.empty?

    items = failed.map { |kind, key, entry| "<li>#{h(kind)} #{h(key)}: #{h(entry['reason'])}</li>" }
    "<h2>Exports that failed</h2><p>These change no case's result.</p><ul>#{items.join}</ul>"
  end

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
                           'skipped' => cases.count { |record| record.skipped? || record.blocked? }.to_s,
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
    elsif record.blocked?
      element.add_element('skipped', 'message' => "blocked_precondition: #{record.blocked_reason}")
    end
    verdict_properties(element, record)
    quarantine_property(element, record)
    element
  end

  # A warn case is a passing testcase that says it warned: never a <failure>,
  # so a CI view that only counts failures keeps passing it, and one that reads
  # properties can still tell a drift from a clean pass.
  def verdict_properties(element, record)
    return unless record.warn?

    properties = element.add_element('properties')
    properties.add_element('property', 'name' => 'cf.verdict', 'value' => 'warn')
    properties.add_element('property', 'name' => 'cf.drift', 'value' => record.relations.any? { |relation| relation['drift'] }.to_s)
  end

  # JUnit consumers read `<properties>`; a quarantined case carries the flag
  # and its reason so a CI view can tell a shielded failure from a gating one.
  def quarantine_property(element, record)
    return unless record.quarantined?

    properties = element.elements['properties'] || element.add_element('properties')
    properties.add_element('property', 'name' => 'quarantined', 'value' => 'true')
    properties.add_element('property', 'name' => 'quarantine_reason', 'value' => record.quarantine_reason.to_s)
  end

  def failure_text(record)
    last = record.attempts.last || {}
    outcome = last['outcome'] || last[:outcome]
    "#{record.key} #{record.status} after #{record.attempts.size} attempt(s)" \
      "#{outcome ? ", last attempt #{outcome}" : ''}; evidence: #{record.evidence_dir || 'none'}"
  end

  def seconds(ms) = format('%.3f', ms / 1000.0)
end
