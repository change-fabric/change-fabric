#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'digest'
require_relative 'pulse_store'

# C5: deterministic integrity checks over the run results a session records in
# <session dir>/pulse_results/*.json. No model call, so it keeps running after
# the model budget is exhausted. It only reads results and the C7 scope; the
# coordinator appends the findings (C1 step 5). A result that is missing
# evidence yields an evidence-gap finding, never a pass.
#
# Result fields: id, verdict, rows, expected, ran, skipped, passed, failed,
# scope_label, head_sha, gate {sha}. `ran` includes `skipped`; when `expected`
# is present it is the denominator, so a runner that omits skipped units from
# `ran` is not misread.
class PulseIntegrity
  COMPREHENSIVE = /\b(comprehensive|full|complete|exhaustive)\b/i
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
    findings = results.flat_map do |name, text, data|
      digest = Digest::SHA256.hexdigest(text)
      check(name, data).map { |finding| finding.merge('result' => name, 'digest' => digest) }
    end
    findings.map { |finding| finding.merge('serves' => serves(finding)).compact }
  end

  def results
    Dir.glob(File.join(@dir, 'pulse_results', '*.json')).sort.map do |file|
      text = File.read(file)
      [ File.basename(file), text, parse(text) ]
    end
  end

  def parse(text)
    data = JSON.parse(text)
    data.is_a?(Hash) ? data : nil
  rescue JSON::ParserError
    nil
  end

  def check(name, data)
    return [ gap(name, 'unreadable', 'result file is not a JSON object') ] unless data

    id = data['id'] || name
    [ vacuous(id, data), skipped_as_pass(id, data), narrowed(id, data), stale_head(id, data), denominator(id, data),
      verdict_gap(id, data) ].compact
  end

  def passing?(data) = data['verdict'].to_s.strip.match?(PASS)

  def verdict_gap(id, data)
    gap(id, 'verdict-unknown', 'result has no verdict') if data['verdict'].to_s.strip.empty?
  end

  def vacuous(id, data)
    return unless passing?(data)

    zero = %w[rows ran].find { |key| data[key].is_a?(Numeric) && data[key].zero? }
    finding(id, 'vacuous-pass', 'P0', "vacuous pass: #{id} recorded PASS with #{zero}: 0", "#{zero}: 0, verdict: #{data['verdict']}") if zero
  end

  # skipped units must not count as passed: passed can reach at most
  # ran - skipped - failed.
  def skipped_as_pass(id, data)
    skipped, ran, passed = data.values_at('skipped', 'ran', 'passed')
    return unless passing?(data) && [ skipped, ran, passed ].all?(Numeric) && skipped.positive?

    total = data['expected'].is_a?(Numeric) ? data['expected'] : ran
    failed = data['failed'].to_i
    return unless passed > total - skipped - failed || passed + failed > ran

    finding(id, 'skipped-as-pass', 'P0', "skipped counted as pass: #{id} skipped #{skipped} and counted them in passed",
            "skipped: #{skipped}, ran: #{ran}, passed: #{passed}, verdict: #{data['verdict']}")
  end

  def narrowed(id, data)
    expected, ran = data.values_at('expected', 'ran')
    return unless passing?(data) && [ expected, ran ].all?(Numeric) && data['scope_label'].to_s.match?(COMPREHENSIVE)

    judged = ran - data['skipped'].to_i
    return unless judged < expected

    finding(id, 'narrowed-comprehensive', 'P0', "narrowed run claims comprehensive coverage: #{id} judged #{judged} of #{expected}",
            "expected: #{expected}, ran: #{ran}, skipped: #{data['skipped'].to_i}, scope_label: #{data['scope_label']}")
  end

  def stale_head(id, data)
    gate = data['gate'].is_a?(Hash) ? data['gate']['sha'].to_s : ''
    head = data['head_sha'].to_s
    return unless passing?(data)
    return gap(id, 'gate-unknown', 'passing result has no gate sha or head sha to bind it') if gate.empty? || head.empty?
    return if gate == head

    finding(id, 'gate-not-bound-to-head', 'P1', "gate evidence not bound to head: #{id} gate sha differs from head sha",
            "gate.sha: #{gate}, head_sha: #{head}", 'queued')
  end

  def denominator(id, data)
    return unless passing?(data) && !data['expected'].is_a?(Numeric)

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
