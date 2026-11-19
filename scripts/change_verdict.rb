#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'

# cf.verdict/1 and cf.heartbeat/1: what the consumer's app-worker controller
# writes and what cf validates. Two layers:
#
#   verdict_errors / heartbeat_errors  shape, and the rules a record must obey
#                                      on its face (a `pass` with stale
#                                      telemetry or incomplete coverage is
#                                      rejected, never downgraded silently)
#   Gate                               actionability against current state:
#                                      rollout revision, stage entry, fencing
#                                      token, seq order, clock skew
#
# Freshness is fail-closed: telemetry older than max_telemetry_age_s reads
# `unknown`, never `pass`, and `unknown` never advances a stage.
module ChangeVerdict
  VERDICT_PROTOCOL = 'cf.verdict/1'
  HEARTBEAT_PROTOCOL = 'cf.heartbeat/1'
  VERDICTS = %w[pass breach unknown].freeze
  COVERAGE = %w[complete incomplete].freeze
  MAX_TELEMETRY_AGE_S = 180
  MAX_FUTURE_SKEW_S = 60
  HEARTBEAT_MAX_GAP_MINUTES = 10
  VERDICT_STRINGS = %w[rollout flag rollout_digest stage stage_entry_id cohort controller_id].freeze
  VERDICT_INTEGERS = %w[rollout_revision fencing_token seq].freeze
  GUARD_KEYS = %w[name observed limit ok].freeze

  module_function

  def verdict_errors(verdict, max_age_s: MAX_TELEMETRY_AGE_S)
    return [ 'verdict must be a JSON object' ] unless verdict.is_a?(Hash)

    errors = []
    errors << "protocol must be '#{VERDICT_PROTOCOL}'" unless verdict['protocol'] == VERDICT_PROTOCOL
    VERDICT_STRINGS.each { |key| errors << "#{key} must be a non-empty string" unless text?(verdict[key]) }
    VERDICT_INTEGERS.each { |key| errors << "#{key} must be a non-negative integer" unless natural?(verdict[key]) }
    errors << "verdict must be one of #{VERDICTS.join(', ')}" unless VERDICTS.include?(verdict['verdict'])
    errors << "coverage must be one of #{COVERAGE.join(', ')}" unless COVERAGE.include?(verdict['coverage'])
    errors.concat(guard_errors(verdict['guards']))
    telemetry_at = parse_time(verdict['telemetry_at'])
    evaluated_at = parse_time(verdict['evaluated_at'])
    errors << 'telemetry_at must be an ISO 8601 time' unless telemetry_at
    errors << 'evaluated_at must be an ISO 8601 time' unless evaluated_at
    errors.concat(pass_errors(verdict, telemetry_at, evaluated_at, max_age_s)) if verdict['verdict'] == 'pass'
    errors
  end

  def guard_errors(guards)
    return [ 'guards must be an array' ] unless guards.is_a?(Array)

    guards.each_with_index.flat_map do |guard, index|
      next [ "guards[#{index}] must be an object" ] unless guard.is_a?(Hash)

      found = (guard.keys - GUARD_KEYS).map { |key| "guards[#{index}].#{key} is not a known key" }
      found << "guards[#{index}].name must be a non-empty string" unless text?(guard['name'])
      found << "guards[#{index}].ok must be true or false" unless [ true, false ].include?(guard['ok'])
      found
    end
  end

  # A pass is only valid on fresh, complete, unbroken evidence.
  def pass_errors(verdict, telemetry_at, evaluated_at, max_age_s)
    errors = []
    errors << "a pass with coverage 'incomplete' is rejected; it must read unknown" if verdict['coverage'] == 'incomplete'
    if telemetry_at && evaluated_at && evaluated_at - telemetry_at > max_age_s
      errors << "a pass whose telemetry is older than #{max_age_s}s at evaluation is rejected; it must read unknown"
    end
    errors << 'a pass cannot carry a failed guard' if Array(verdict['guards']).any? { |g| g.is_a?(Hash) && g['ok'] == false }
    errors
  end

  def heartbeat_errors(heartbeat)
    return [ 'heartbeat must be a JSON object' ] unless heartbeat.is_a?(Hash)

    errors = []
    errors << "protocol must be '#{HEARTBEAT_PROTOCOL}'" unless heartbeat['protocol'] == HEARTBEAT_PROTOCOL
    %w[controller_id rollout].each { |key| errors << "#{key} must be a non-empty string" unless text?(heartbeat[key]) }
    %w[fencing_token rollout_revision].each { |key| errors << "#{key} must be a non-negative integer" unless natural?(heartbeat[key]) }
    errors << 'at must be an ISO 8601 time' unless parse_time(heartbeat['at'])
    errors
  end

  # What the controller should have recorded for this evidence: a stale or
  # incomplete `pass` degrades to `unknown`; a breach and an unknown stand.
  def effective_verdict(verdict, now:, max_age_s: MAX_TELEMETRY_AGE_S)
    return 'unknown' unless verdict.is_a?(Hash) && VERDICTS.include?(verdict['verdict'])
    return verdict['verdict'] unless verdict['verdict'] == 'pass'

    telemetry_at = parse_time(verdict['telemetry_at'])
    return 'unknown' if verdict['coverage'] != 'complete' || telemetry_at.nil? || now - telemetry_at > max_age_s

    'pass'
  end

  # True when the controller has been silent longer than the allowed gap.
  def heartbeat_gap?(last_at, now:, max_gap_minutes: HEARTBEAT_MAX_GAP_MINUTES)
    last = parse_time(last_at)
    last.nil? || now - last > max_gap_minutes * 60
  end

  # Tracks what cf (or a controller) has accepted for one rollout, and decides
  # whether the next verdict may act. Reasons are stable symbols, logged by the
  # caller: :stale_revision, :wrong_stage_entry, :fenced, :replayed, :future.
  class Gate
    attr_reader :rollout_revision, :stage_entry_id, :fencing_floor, :last_seq

    def initialize(rollout_revision:, stage_entry_id:, fencing_floor: 0)
      @rollout_revision = rollout_revision
      @stage_entry_id = stage_entry_id
      @fencing_floor = fencing_floor
      @last_seq = -1
    end

    # Returns [true, nil] and records the verdict, or [false, reason]. A new
    # stage entry (including a triage re-enable) resets seq so earlier passes
    # are never reused.
    def accept(verdict, now:)
      reason = rejection(verdict, now)
      return [ false, reason ] if reason

      @fencing_floor = verdict['fencing_token']
      @last_seq = verdict['seq']
      [ true, nil ]
    end

    def enter_stage(stage_entry_id)
      @stage_entry_id = stage_entry_id
      @last_seq = -1
    end

    private

    def rejection(verdict, now)
      return :stale_revision unless verdict['rollout_revision'] == @rollout_revision
      return :wrong_stage_entry unless verdict['stage_entry_id'] == @stage_entry_id
      return :fenced if verdict['fencing_token'] < @fencing_floor
      return :replayed if verdict['seq'] <= @last_seq

      evaluated_at = ChangeVerdict.parse_time(verdict['evaluated_at'])
      :future if evaluated_at.nil? || evaluated_at - now > MAX_FUTURE_SKEW_S
    end
  end

  def parse_time(value)
    return nil unless value.is_a?(String)

    Time.iso8601(value)
  rescue ArgumentError
    nil
  end

  def text?(value) = value.is_a?(String) && !value.strip.empty?
  def natural?(value) = value.is_a?(Integer) && !value.negative?
end
