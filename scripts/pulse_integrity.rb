#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'digest'
require 'set'
require_relative 'pulse_store'

# C5: deterministic integrity checks over the run results a session records in
# <session dir>/pulse_results/*.json. No model call, so it keeps running after
# the model budget is exhausted. It only reads results and the C7 scope; the
# coordinator appends the findings (C1 step 5). A result that is missing
# evidence yields an evidence-gap finding, never a pass.
#
# Result fields: id, verdict, rows, expected, ran, skipped, passed, failed, judged,
# scope_label, head_sha, gate {sha}. `ran` includes `skipped`; when `expected`
# is present it is the denominator, so a runner that omits skipped units from
# `ran` is not misread.
class PulseIntegrity
  COMPREHENSIVE = /\b(comprehensive|full|complete|exhaustive)\b/i
  FAIL = /\A(fail|failed|failing|error|errored|red|false|no)\z/i
  BAD = :malformed
  COUNTERS = %w[rows ran passed skipped failed judged expected].freeze
  MAX_BYTES = 2_000_000
  PASS = /\A(pass|passed|passing|ok|success|succeeded|green|true)\z/i

  def initialize(session)
    @session = session
    @dir = Pulse.session_dir(session)
    @store = PulseStore.new(session)
  end

  # Findings for results whose content changed since the cursor digest. The
  # cursor is not advanced here; `commit` does that once they are appended.
  def run
    seen = @store.cursor['integrity_digests'] || {}
    scan.reject { |finding| seen[finding['result']] == finding['digest'] }
  end

  # Records a result's digest only when every finding it produced is in the
  # given list (the appended findings from `run`), so a partial append is
  # retried whole. Forgets results whose file is gone.
  def commit(appended)
    done = appended.map { |finding| [ finding['result'], finding['digest'], finding['anchor'] ] }
    kept = (@store.cursor['integrity_digests'] || {}).slice(*results.map(&:first))
    scan.group_by { |finding| [ finding['result'], finding['digest'] ] }.each do |(name, digest), found|
      kept[name] = digest if found.all? { |finding| done.include?([ name, digest, finding['anchor'] ]) }
    end
    @store.advance_cursor('integrity_digests' => kept)
  end

  private

  def scan
    seen = Set.new
    findings = results.flat_map do |name, body, data|
      digest = Digest::SHA256.hexdigest(body)
      check(name, data, seen).map { |finding| finding.merge('result' => name, 'digest' => digest) }
    end
    findings.uniq { |finding| [ finding['result'], finding['anchor'] ] }
            .map { |finding| finding.merge('serves' => serves(finding)).compact }
  end

  def results
    Dir.glob(File.join(@dir, 'pulse_results', '*.json')).sort.map do |file|
      text = File.size(file) > MAX_BYTES ? "oversized #{File.size(file)}" : File.read(file)
      [ File.basename(file), text, parse(text) ]
    rescue SystemCallError
      [ File.basename(file), 'unreadable', nil ]
    end
  end

  # A result that is too large, truncated, nested past the parser limit, or not
  # an object parses to nil, which `check` reports as an evidence gap.
  def parse(text)
    data = JSON.parse(text)
    data.is_a?(Hash) ? data : nil
  rescue StandardError
    nil
  end

  def check(name, data, seen)
    return [ gap(name, 'unreadable', 'result file is oversized, truncated or not a JSON object') ] unless data

    id = text(data['id']).then { |value| value.empty? ? name : value }
    dup = seen.add?(id) ? nil : gap(name, 'duplicate-record', "result id #{id} already appears in another result file")
    id = name if dup
    counts, bad = counters(data)
    [ dup, vacuous(id, data, counts), skipped_as_pass(id, data, counts), narrowed(id, data, counts), stale_head(id, data),
      denominator(id, data, counts), verdict_gap(id, data), execution_gap(id, data, counts), malformed(id, data, bad),
      inconsistent(id, data, counts) ].compact
  rescue StandardError => e
    [ gap(name, 'unreadable', "result could not be checked: #{e.class}") ]
  end

  # The one coercion for every counter field: an absent or null field is nil
  # (unknown), a non-negative integer (or an integral finite float) is itself,
  # and anything else (false, a string, a negative, a fraction, NaN, a nested
  # value) is malformed. Malformed reads as unknown in every check and is
  # reported as an evidence gap, never as healthy and never as a crash.
  def counters(data)
    bad = []
    counts = COUNTERS.to_h do |key|
      value = count(data[key])
      bad << key if value == BAD
      [ key, value == BAD ? nil : value ]
    end
    [ counts, bad ]
  end

  def count(value)
    case value
    when nil then nil
    when Integer then value.negative? ? BAD : value
    when Float then value.finite? && !value.negative? && value == value.floor ? value.to_i : BAD
    else BAD
    end
  end

  def text(value) = value.is_a?(String) ? value.scrub.strip : ''

  def label(data) = data['scope_label'].is_a?(String) ? text(data['scope_label']) : data['scope_label'].to_s.scrub

  def verdict(data) = [ true, false ].include?(data['verdict']) ? data['verdict'].to_s : text(data['verdict'])

  def passing?(data) = verdict(data).match?(PASS)

  def malformed(id, data, bad)
    return if bad.empty?

    gap(id, 'counter-malformed', bad.map { |key| "#{key}: #{data[key].inspect[0, 40]}" }.join(', '))
  end

  # A pass that reports no execution count at all cannot show anything ran.
  def execution_gap(id, data, counts)
    return unless passing?(data) && %w[rows ran passed judged].all? { |key| counts[key].nil? }

    gap(id, 'execution-unknown', 'passing result reports no rows, ran, passed or judged count')
  end

  def verdict_gap(id, data)
    return gap(id, 'verdict-unknown', 'result has no verdict') if verdict(data).empty?

    gap(id, 'verdict-unrecognized', "verdict #{verdict(data)[0, 40].inspect} is not a known pass or fail") unless passing?(data) || verdict(data).match?(FAIL)
  end

  # Counts that contradict each other on a pass: more passed than ran, any
  # failure, or more ran than the inventory.
  def inconsistent(id, data, counts)
    return unless passing?(data)

    ran, passed, failed, expected = counts.values_at('ran', 'passed', 'failed', 'expected')
    return unless (ran && passed && passed > ran) || failed.to_i.positive? || (ran && expected && ran > expected)

    gap(id, 'counts-inconsistent', "ran: #{ran.inspect}, passed: #{passed.inspect}, failed: #{failed.inspect}, expected: #{expected.inspect}")
  end

  # A pass whose execution count is zero by any field cannot show anything ran.
  def vacuous(id, data, counts)
    return unless passing?(data)

    zero = %w[rows ran passed judged].find { |key| counts[key]&.zero? }
    finding(id, 'vacuous-pass', 'P0', "vacuous pass: #{id} recorded PASS with #{zero}: 0", "#{zero}: 0, verdict: #{verdict(data)}") if zero
  end

  # skipped units must not count as passed: passed can reach at most
  # ran - skipped - failed.
  def skipped_as_pass(id, data, counts)
    skipped, ran, passed = counts.values_at('skipped', 'ran', 'passed')
    return unless passing?(data) && [ skipped, ran, passed ].none?(&:nil?) && skipped.positive?

    total = counts['expected'] || ran
    failed = counts['failed'].to_i
    return unless passed > total - skipped - failed || passed + failed > ran

    finding(id, 'skipped-as-pass', 'P0', "skipped counted as pass: #{id} skipped #{skipped} and counted them in passed",
            "skipped: #{skipped}, ran: #{ran}, passed: #{passed}, verdict: #{verdict(data)}")
  end

  def narrowed(id, data, counts)
    expected, ran = counts.values_at('expected', 'ran')
    return unless passing?(data) && expected && ran && label(data).match?(COMPREHENSIVE)

    judged = counts['judged'] || ran - counts['skipped'].to_i
    return unless judged < expected

    finding(id, 'narrowed-comprehensive', 'P0', "narrowed run claims comprehensive coverage: #{id} judged #{judged} of #{expected}",
            "expected: #{expected}, ran: #{ran}, skipped: #{counts['skipped'].to_i}, scope_label: #{label(data)}")
  end

  def stale_head(id, data)
    gate = data['gate'].is_a?(Hash) ? text(data['gate']['sha']) : ''
    head = text(data['head_sha'])
    return unless passing?(data)
    return gap(id, 'gate-unknown', 'passing result has no gate sha or head sha to bind it') if gate.empty? || head.empty?
    return if gate == head

    finding(id, 'gate-not-bound-to-head', 'P1', "gate evidence not bound to head: #{id} gate sha differs from head sha",
            "gate.sha: #{gate}, head_sha: #{head}", 'queued')
  end

  def denominator(id, data, counts)
    return unless passing?(data) && counts['expected'].nil?

    gap(id, 'denominator-unknown', 'result carries no expected inventory, so coverage cannot be judged')
  end

  def gap(id, anchor, evidence)
    finding(id, "evidence-gap-#{anchor}", 'P1', "evidence gap: #{id} cannot be verified", evidence, 'queued')
  end

  def finding(id, check, severity, claim, evidence, disposition = 'interrupt')
    { 'kind' => 'integrity', 'severity' => severity, 'claim' => claim, 'subject' => "#{check} #{id}", 'evidence' => evidence,
      'anchor' => "#{id} #{check} #{Pulse.sha(evidence)[0, 12]}", 'action_class' => 'report', 'check' => check,
      'route' => disposition }
  end

  # The run goal when resolved, else the project goal. With neither, the
  # finding carries no `serves` and the coordinator appends it with
  # `pulse_store.rb append-system`, so it is stored and still delivered.
  def serves(finding)
    source = scope_sources.min_by { |src| src['role'] == 'run_goal' ? 0 : 1 }
    return unless source

    text = File.read(File.expand_path(source['source_path']))
    quote = text.lines.map(&:strip).find { |line| !line.empty? && !line.start_with?('#') }&.slice(0, 160)
    return unless quote

    { 'source_path' => source['source_path'], 'revision' => source['revision'], 'quote' => quote,
      'relevance' => "#{finding['check'].tr('-', ' ')} means this result cannot show the goal was met." }
  rescue StandardError
    nil
  end

  def scope_sources
    file = File.join(@dir, 'pulse_scope.json')
    File.file?(file) ? Array(JSON.parse(File.read(file))['sources']) : []
  rescue JSON::ParserError
    []
  end
end

if __FILE__ == $PROGRAM_NAME
  opts = ARGV.reject { |arg| arg == '--json' }.each_slice(2).to_h { |flag, value| [ flag.delete_prefix('--'), value ] }
  abort 'usage: pulse_integrity.rb --session ID --json | --session ID --commit true (findings JSON on stdin)' unless opts['session']
  check = PulseIntegrity.new(opts['session'])
  if opts['commit'] == 'true'
    check.commit(JSON.parse($stdin.read))
    puts JSON.generate(committed: true)
  else
    puts JSON.generate(check.run)
  end
end
