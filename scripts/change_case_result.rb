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
  # `warn` (suite_version 8) passed on every check but needed a re-read to
  # agree with itself (drift). `blocked_precondition` could not be verified at
  # all: a login, a record or a reference it needed was not there. Neither is a
  # failure, and neither is a pass.
  STATUSES = %w[pass warn blocked_precondition fail auth_interrupted partial_evidence skipped].freeze
  # A case in one of these failed. `skipped` is neither a failure nor a pass.
  FAILURE_STATUSES = %w[fail auth_interrupted partial_evidence].freeze

  # How bad a status is, for the worst-of roll-up: pass < warn <
  # blocked_precondition < fail, every failure status ranking as fail.
  SEVERITY = { 'pass' => 0, 'warn' => 1, 'blocked_precondition' => 2, 'fail' => 3 }.freeze

  # `vars` are the figures the case read (each with its provenance), `relations`
  # the relation checks that decided it, and `blocked_reason` why it could not
  # be verified.
  FIELDS = %i[key suite id persona status attempts duration_ms started_at commit run_id evidence_dir
              acceptance_verdict step_durations quarantined quarantine_reason case_hash selector_suggestions
              visual_results vars relations blocked_reason].freeze

  attr_reader(*FIELDS)

  def initialize(**fields)
    unknown = fields.keys - FIELDS
    raise ArgumentError, "unknown case-result field(s): #{unknown.join(', ')}" if unknown.any?
    raise ArgumentError, "unknown case status: #{fields[:status].inspect}" unless STATUSES.include?(fields[:status].to_s)

    FIELDS.each { |field| instance_variable_set(:"@#{field}", fields[field]) }
    @status = @status.to_s
    @attempts = Array(@attempts)
    @step_durations = Array(@step_durations)
    @quarantined = @quarantined == true
    @quarantine_reason = @quarantine_reason.to_s unless @quarantine_reason.nil?
    @case_hash = @case_hash.to_s unless @case_hash.nil?
    @selector_suggestions = Array(@selector_suggestions).grep(Hash)
    @visual_results = Array(@visual_results).grep(Hash)
    @vars = Array(@vars)
    @relations = Array(@relations)
  end

  # The worst status among results (or status strings), pass when there are
  # none. Skipped cases do not count: a case that did not run says nothing.
  def self.worst_status(items)
    statuses = Array(items).map { |item| item.respond_to?(:status) ? item.status : item.to_s }.reject { |status| status == 'skipped' }
    statuses = statuses.map { |status| FAILURE_STATUSES.include?(status) ? 'fail' : status }
    statuses.max_by { |status| SEVERITY.fetch(status) } || 'pass'
  end

  def self.from_h(hash)
    new(**hash.transform_keys(&:to_sym).slice(*FIELDS))
  end

  def to_h = FIELDS.to_h { |field| [ field.to_s, public_send(field) ] }

  def to_json(*) = JSON.generate(to_h)

  # Whether a live quarantine was shielding this case from the gate in this
  # run. The result still says what happened; this says it was not gating.
  def quarantined? = quarantined

  def failure? = FAILURE_STATUSES.include?(status)

  def pass? = status == 'pass'

  def skipped? = status == 'skipped'

  def warn? = status == 'warn'

  def blocked? = status == 'blocked_precondition'

  # Passed, but only after a failed attempt.
  def flaky? = pass? && attempts.size > 1

  # What this result means against the case's history, the earlier records
  # for any keys, oldest first:
  #   :newly_failing  failing now, and the last run that executed it passed
  #   :failing        failing now, and failing (or never passed) before
  #   :no_history     failing now, with no earlier executed run to compare
  #   :flaky, :pass, :skipped as the status says
  # Runs where the case was skipped, blocked or not selected are passed over,
  # not compared: a gap in the history is not evidence about the case.
  def trend(history)
    return :skipped if skipped?
    return :warn if warn?
    return :blocked if blocked?
    return flaky? ? :flaky : :pass unless failure?

    previous = self.class.previous_executed(history, key)
    return :no_history unless previous

    previous.pass? ? :newly_failing : :failing
  end

  # The most recent earlier record for `key` whose case actually ran.
  def self.previous_executed(history, key)
    history.reverse_each.find { |record| record.key == key && !record.skipped? && !record.blocked? }
  end
end
