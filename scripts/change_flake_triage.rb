#!/usr/bin/env ruby
# frozen_string_literal: true

require 'date'
require 'fileutils'
require 'json'
require 'optparse'
require_relative 'change_case_result'

# Flake triage: reads the testcases history ledger and proposes a time-boxed
# quarantine for each case that flips between pass and fail while its own
# definition stays the same. It writes flake-proposals.md and
# flake-proposals.json to a run output directory and nothing else. It never
# edits a suite: accepting a proposal is a person pasting the YAML patch.
#
# A flip is two neighbouring executed runs with different outcomes. Only runs
# at the case's newest `case_hash` count, so a case that was edited is judged
# on the edited definition alone. A skipped run is a gap, not evidence. Records
# written before `case_hash` existed share the empty hash, so they compare with
# each other and never with a hashed run.
#
# Every value that reaches a proposal (a key, a step label) is stripped of
# control characters, redacted when it looks like a credential, and truncated.
class ChangeFlakeTriage
  class Error < StandardError; end

  DEFAULT_RUNS = 10
  DEFAULT_THRESHOLD = 2
  QUARANTINE_DAYS = 7
  JSON_FILE = 'flake-proposals.json'
  MARKDOWN_FILE = 'flake-proposals.md'
  CLIP = 80
  ID_CLIP = 120
  SECRET = /(token|secret|passw(?:or)?d|api[_-]?key|authorization|bearer|cookie)\W{0,3}\S+|\$\{[^}]*\}/i

  Proposal = Struct.new(:key, :flips, :window, :statuses, :last_failing_step, :case_hash, :until_on, keyword_init: true)

  # A value fit for a report: control characters gone, credential shapes
  # redacted, truncated.
  def self.safe(value, max = CLIP)
    text = value.to_s.gsub(/[[:cntrl:]]/, ' ').gsub(SECRET, '[redacted]')
    text.length > max ? "#{text[0, max]}..." : text
  end

  # The ledger's records, oldest first. A missing file, a blank line, a line
  # that is not a JSON object and a record with an unknown status are all
  # passed over.
  def self.read_ledger(path)
    return [] unless path && File.file?(path)

    File.foreach(path, encoding: 'UTF-8').filter_map do |line|
      parsed = JSON.parse(line.scrub)
      ChangeCaseResult.from_h(parsed) if parsed.is_a?(Hash)
    rescue JSON::ParserError, ArgumentError, TypeError
      nil
    end
  end

  attr_reader :runs, :threshold, :today

  def initialize(records, runs: DEFAULT_RUNS, threshold: DEFAULT_THRESHOLD, today: Date.today)
    @runs = integer(runs, 'runs', 2)
    @threshold = integer(threshold, 'threshold', 1)
    @today = today
    @records = Array(records)
  end

  def proposals
    @proposals ||= analysed.fetch(:proposals)
  end

  # Keys whose newest record is under a live quarantine: flaky, but already
  # shielded, so nothing is proposed for them.
  def already_quarantined
    @already_quarantined ||= analysed.fetch(:already_quarantined)
  end

  def examined = @records.map(&:key).uniq.size

  def to_h
    { 'version' => 1, 'runs' => runs, 'threshold' => threshold, 'examined' => examined,
      'proposals' => proposals.map { |item| proposal_h(item) },
      'already_quarantined' => already_quarantined.map { |key| self.class.safe(key, ID_CLIP) } }
  end

  def to_markdown
    lines = [ '# Flake proposals', '',
              "Proposals only: no suite was edited. Window #{runs} runs, threshold #{threshold} flips, " \
              "#{examined} case(s) examined.", '' ]
    lines.concat(proposals.empty? ? [ 'No case is flipping.', '' ] : proposal_sections)
    lines.concat([ '## Already quarantined', '', *already_quarantined.map { |key| "- #{cell(key)}" }, '' ]) if already_quarantined.any?
    "#{lines.join("\n")}\n"
  end

  # Writes both files into `dir` and returns their paths.
  def write(dir)
    FileUtils.mkdir_p(dir)
    json = File.join(dir, JSON_FILE)
    markdown = File.join(dir, MARKDOWN_FILE)
    File.write(json, "#{JSON.pretty_generate(to_h)}\n")
    File.write(markdown, to_markdown)
    { json: json, markdown: markdown }
  end

  private

  def integer(value, name, minimum)
    number = Integer(value, exception: false)
    raise Error, "#{name} must be an integer of at least #{minimum}, got #{self.class.safe(value).inspect}" if number.nil? || number < minimum

    number
  end

  def analysed
    @analysed ||= begin
      found = []
      shielded = []
      @records.group_by(&:key).each do |key, history|
        executed = history.reject(&:skipped?)
        next if executed.empty?

        proposal = assess(key, executed)
        next unless proposal

        if executed.last.quarantined?
          shielded << key
        else
          found << proposal
        end
      end
      { proposals: found.sort_by { |item| [ -item.flips, item.key.to_s ] }, already_quarantined: shielded.sort }
    end
  end

  def assess(key, executed)
    hash = executed.last.case_hash
    window = executed.select { |record| record.case_hash == hash }.last(runs)
    outcomes = window.map { |record| record.failure? ? 'fail' : 'pass' }
    flips = outcomes.each_cons(2).count { |before, after| before != after }
    return if flips < threshold

    Proposal.new(key: key, flips: flips, window: window.size, statuses: outcomes, case_hash: hash,
                 last_failing_step: last_failing_step(window), until_on: today + QUARANTINE_DAYS)
  end

  # The last step the newest failing run reached; the run stops at the step
  # that fails, so it is the failing step. Nil when that run recorded none.
  def last_failing_step(window)
    failed = window.reverse.find(&:failure?)
    step = failed&.step_durations&.last
    return unless step.is_a?(Hash)

    { 'index' => step['index'], 'verb' => self.class.safe(step['verb']), 'label' => step['label'] && self.class.safe(step['label']) }
  end

  def proposal_h(item)
    { 'key' => self.class.safe(item.key, ID_CLIP), 'flips' => item.flips, 'window' => item.window,
      'outcomes' => item.statuses, 'last_failing_step' => item.last_failing_step, 'case_hash' => item.case_hash,
      'quarantine_until' => item.until_on.iso8601, 'patch' => patch(item) }
  end

  def proposal_sections
    proposals.flat_map do |item|
      [ "## #{cell(item.key)}", '',
        "- Flips: #{item.flips} in the last #{item.window} run(s): #{item.statuses.join(' ')}",
        "- Last failing step: #{step_text(item.last_failing_step)}",
        "- Proposed quarantine until: #{item.until_on.iso8601}", '',
        '```yaml', patch(item).tr('`', "'"), '```', '' ]
    end
  end

  def step_text(step)
    return 'not recorded' unless step

    label = step['label'] ? " (#{cell(step['label'])})" : ''
    "step #{step['index'].is_a?(Integer) ? step['index'] : '?'} #{cell(step['verb'])}#{label}"
  end

  # The YAML to paste into the suite file under the case, as a comment-led
  # patch. Strings are JSON-quoted, which YAML reads as written.
  def patch(item)
    id = item.key.to_s.split('/', 2).last
    reason = "flipped #{item.flips} times in the last #{item.window} runs"
    "# case #{JSON.generate(self.class.safe(id, ID_CLIP))}\n" \
      "quarantined: true\n" \
      "quarantine_reason: #{JSON.generate(reason)}\n" \
      "quarantine_until: #{item.until_on.iso8601}"
  end

  def cell(text) = self.class.safe(text, ID_CLIP).gsub(/[|`]/, ' ')
end

if $PROGRAM_NAME == __FILE__
  options = { runs: ChangeFlakeTriage::DEFAULT_RUNS, threshold: ChangeFlakeTriage::DEFAULT_THRESHOLD }
  begin
    OptionParser.new do |opts|
      opts.banner = 'Usage: change_flake_triage.rb --ledger PATH --out DIR [--runs N] [--threshold N]'
      opts.on('--ledger PATH') { |value| options[:ledger] = value }
      opts.on('--out DIR') { |value| options[:out] = value }
      opts.on('--runs N') { |value| options[:runs] = value }
      opts.on('--threshold N') { |value| options[:threshold] = value }
    end.parse!
    raise ChangeFlakeTriage::Error, '--ledger and --out are required' unless options[:ledger] && options[:out]

    triage = ChangeFlakeTriage.new(ChangeFlakeTriage.read_ledger(options[:ledger]), runs: options[:runs], threshold: options[:threshold])
    paths = triage.write(options[:out])
    puts "flake triage: #{triage.proposals.size} proposal(s), #{triage.already_quarantined.size} already quarantined: #{paths[:markdown]}"
  rescue OptionParser::ParseError, ChangeFlakeTriage::Error, SystemCallError => e
    warn "flake triage: #{ChangeFlakeTriage.safe(e.message, 200)}"
    exit 2
  end
end
