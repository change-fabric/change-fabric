#!/usr/bin/env ruby
# frozen_string_literal: true

# One audit result from any change-fabric lane, plus the collection that gathers
# them. A Finding is deliberately lane-agnostic: k6 thresholds, axe violations,
# ZAP alerts, and browserless viewport checks all reduce to the same shape so the
# CSV and Markdown renderers never branch on which lane produced a row. The lane
# scripts translate their own tool output into these; nothing downstream needs to
# know a ZAP alert from an axe rule.
#
# `status` is the gate signal in {pass, warn, fail}: a lane passes when it emits
# no `fail`, and a whole run passes when every enabled lane passes. `severity` is
# the lane's own free-text grade (a k6 threshold name, an axe impact, a ZAP risk)
# kept for the report, never for the gate decision.
#
# `attempts` and `flaky` record how the verdict was reached, never what it is.
# A run may retry a lane (opt-in, 0 retries by default); a finding that only
# stopped failing on a later attempt is recorded as its real status with
# `flaky: true` beside it, so a pass bought by a re-run is legible as one
# instead of being laundered into a clean result. Deliberately not a fourth
# status: {pass, warn, fail} stays the sole gate signal.
class Finding
  STATUSES = %w[pass warn fail].freeze

  attr_reader :lane, :target, :check, :status, :severity, :detail, :location, :help, :attempts, :flaky

  def initialize(lane:, check:, status:, target: '', severity: '', detail: '', location: '', help: '',
                 attempts: 1, flaky: false)
    @lane = lane.to_s
    @target = target.to_s
    @check = check.to_s
    @status = normalize_status(status)
    @severity = severity.to_s
    @detail = detail.to_s
    @location = location.to_s
    @help = help.to_s
    @attempts = normalize_attempts(attempts)
    @flaky = flaky == true
  end

  def fail? = @status == 'fail'
  def pass? = @status == 'pass'

  # A copy of this finding carrying the retry bookkeeping the runner learned
  # after the lane had already built it. A Finding is never mutated in place:
  # the lane owns the verdict, the runner only annotates how many attempts it
  # took to get there.
  def with_attempt(attempts:, flaky:)
    self.class.new(lane: @lane, check: @check, status: @status, target: @target, severity: @severity,
                   detail: @detail, location: @location, help: @help, attempts: attempts, flaky: flaky)
  end

  # Column order is the CSV header order; keep the two in lockstep.
  def to_row
    [ @lane, @status, @severity, @target, @check, @location, @detail, @help, @attempts, @flaky.to_s ]
  end

  private

  # A finding is the product of at least one attempt; a nonsense or missing
  # count reads as the single attempt every lane makes by default rather than
  # as a zero no run could have produced.
  def normalize_attempts(value)
    count = value.to_i
    count.positive? ? count : 1
  end

  def normalize_status(value)
    text = value.to_s.downcase
    STATUSES.include?(text) ? text : 'fail'
  end
end

# An ordered bag of findings with the roll-up predicates the runner and the merge
# gate both read. It never mutates a Finding; lanes build findings and append.
class Findings
  HEADER = %w[lane status severity target check location detail help attempts flaky].freeze

  include Enumerable

  def initialize = @items = []

  def each(&) = @items.each(&)
  def empty? = @items.empty?
  def size = @items.size

  def add(finding)
    @items << finding
    finding
  end

  def concat(other)
    other.each { |finding| @items << finding }
    self
  end

  def failures = @items.select(&:fail?)
  def passed? = failures.empty?

  # Findings that only stopped failing on a later attempt. Never part of the
  # gate decision; the report names them so a green run bought by a retry is
  # visibly that.
  def flaky = @items.select(&:flaky)

  def lanes = @items.map(&:lane).uniq

  # Per-lane pass/fail, used by the Markdown summary and the gate record so a
  # single failing lane is named rather than buried in a total.
  def lane_status
    lanes.to_h do |lane|
      rows = @items.select { |item| item.lane == lane }
      [ lane, rows.any?(&:fail?) ? 'fail' : 'pass' ]
    end
  end

  def rows = @items.map(&:to_row)
end
