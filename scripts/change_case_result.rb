#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'

# One test case's outcome in one run: the record the testcases lane writes,
# and the only thing a report, a JUnit file or the history ledger reads. One
# shape for all of them, so the HTML page, the CI view and the ledger can never
# disagree about what happened to a case.
#
# `key` is `<suite>/<id>`, the case's identity across runs.
class ChangeCaseResult
  STATUSES = %w[pass fail auth_interrupted partial_evidence skipped].freeze
  # A case in one of these failed. `skipped` is neither a failure nor a pass.
  FAILURE_STATUSES = %w[fail auth_interrupted partial_evidence].freeze

  FIELDS = %i[key suite id persona status attempts duration_ms started_at commit run_id evidence_dir
              acceptance_verdict step_durations].freeze

  attr_reader(*FIELDS)

  def initialize(**fields)
    unknown = fields.keys - FIELDS
    raise ArgumentError, "unknown case-result field(s): #{unknown.join(', ')}" if unknown.any?
    raise ArgumentError, "unknown case status: #{fields[:status].inspect}" unless STATUSES.include?(fields[:status].to_s)

    FIELDS.each { |field| instance_variable_set(:"@#{field}", fields[field]) }
    @status = @status.to_s
    @attempts = Array(@attempts)
    @step_durations = Array(@step_durations)
  end

  def self.from_h(hash)
    new(**hash.transform_keys(&:to_sym).slice(*FIELDS))
  end

  def to_h = FIELDS.to_h { |field| [ field.to_s, public_send(field) ] }

  def to_json(*) = JSON.generate(to_h)

  def failure? = FAILURE_STATUSES.include?(status)

  def pass? = status == 'pass'

  def skipped? = status == 'skipped'

  # Passed, but only after a failed attempt.
  def flaky? = pass? && attempts.size > 1

  # What this result means against the case's history, the earlier records
  # for any keys, oldest first:
  #   :newly_failing  failing now, and the last run that executed it passed
  #   :failing        failing now, and failing (or never passed) before
  #   :no_history     failing now, with no earlier executed run to compare
  #   :flaky, :pass, :skipped as the status says
  # Runs where the case was skipped or not selected are passed over, not
  # compared: a gap in the history is not evidence about the case.
  def trend(history)
    return :skipped if skipped?
    return flaky? ? :flaky : :pass unless failure?

    previous = self.class.previous_executed(history, key)
    return :no_history unless previous

    previous.pass? ? :newly_failing : :failing
  end

  # The most recent earlier record for `key` whose case actually ran.
  def self.previous_executed(history, key)
    history.reverse_each.find { |record| record.key == key && !record.skipped? }
  end
end
