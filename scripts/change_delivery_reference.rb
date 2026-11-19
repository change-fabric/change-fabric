#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'

# A reference cf.verdict/1 controller, small enough to read in one sitting. It
# replays a conformance trace (see test/fixtures/delivery/traces) and prints
# the transitions the normative controller semantics require. It exists so the
# traces are proven satisfiable and so a consumer has a worked example; the
# consumer's real controller runs in its own app worker.
#
# stdin:  a trace JSON object without `expect`
# stdout: {"transitions": [{step, verdict, action, stage}, ...]}
class ChangeDeliveryReference
  EVERYONE_WATCH_S = 7 * 24 * 3600

  def initialize(trace)
    @stages = trace.fetch('rollout').fetch('stages')
    @pacing = trace.dig('rollout', 'pacing') || {}
    @guards = trace.dig('rollout', 'guards') || {}
    @policy = { 'max_telemetry_age_s' => 180, 'min_baseline_requests' => 50 }.merge(trace['policy'] || {})
    @steps = trace.fetch('steps')
    @index = 0
    @dwell_s = 0
    @requests = 0
    @previous_at = 0
    @done = false
  end

  def run
    @steps.each_with_index.map { |step, i| transition(i, step) }
  end

  private

  def transition(index, step)
    verdict = evaluate(step)
    action = decide(verdict, step)
    @previous_at = step['at_s']
    { 'step' => index, 'verdict' => verdict, 'action' => action, 'stage' => @stages[@index]['cohort'] }
  end

  # Breach outranks unknown; unknown never reads as pass.
  def evaluate(step)
    return 'breach' if breach?(step)
    return 'unknown' if unknown?(step)

    'pass'
  end

  def breach?(step)
    return true if step['new_5xx'].to_i > guard_max('new_5xx_on_flagged_spans')
    return true if step['new_exceptions'].to_i > guard_max('new_exceptions_on_flagged_spans')

    ratio = step['p95_ratio']
    !ratio.nil? && baseline_ok?(step) && ratio > p95_limit
  end

  def unknown?(step)
    step['coverage'] != 'complete' || step['telemetry_age_s'].to_i > @policy['max_telemetry_age_s'] ||
      step['requests'].to_i.zero? || !baseline_ok?(step)
  end

  def baseline_ok?(step) = step['baseline_requests'].to_i >= @policy['min_baseline_requests']
  def guard_max(name) = @guards.dig(name, 'max') || 0
  def p95_limit = @guards.dig('p95_ms_vs_baseline', 'max_ratio') || 1.25

  def decide(verdict, step)
    return 'complete' if @done
    return 'halted' if @halted
    return halt if verdict == 'breach'

    @requests += step['requests'].to_i
    return 'hold' unless verdict == 'pass'

    @dwell_s += step['at_s'] - @previous_at
    stage_ready? ? advance(step) : 'hold'
  end

  def stage_ready?
    stage = @stages[@index]
    return @dwell_s >= EVERYONE_WATCH_S if last_stage?

    @dwell_s >= stage['dwell_minutes'].to_i * 60 && @requests >= stage['min_requests'].to_i
  end

  # A breach turns the flag off and latches: nothing advances until recovery.
  def halt
    @halted = true
    'disable'
  end

  def last_stage? = @index == @stages.length - 1

  def advance(step)
    return finish if last_stage?

    needs_approval = manual?(@stages[@index]) || @stages[@index + 1]['cohort'] == 'everyone'
    return 'await_approval' if needs_approval && !step['approval']

    @index += 1
    @dwell_s = 0
    @requests = 0
    'advance'
  end

  def finish
    @done = true
    'complete'
  end

  def manual?(stage)
    return true if @pacing['money_affecting']

    (stage['advance'] || @pacing['advance'] || 'auto') == 'manual'
  end
end

if $PROGRAM_NAME == __FILE__
  trace = JSON.parse($stdin.read)
  puts JSON.generate('transitions' => ChangeDeliveryReference.new(trace).run)
end
