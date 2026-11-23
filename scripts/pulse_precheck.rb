#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'pulse_store'

# C2: a deterministic gate that skips the model call when nothing changed.
# Time counts as change: a crossed deadline or an unconsumed watcher event
# makes a pass due even when every file and counter is frozen.
class PulsePrecheck
  STALL_S = 1800
  OVER_BUDGET = 1.5
  INTERVAL_S = 1200
  MAX_INTERVAL_S = 3600

  def self.interval_s(empty_passes) = [ INTERVAL_S * (2**empty_passes.to_i), MAX_INTERVAL_S ].min

  def initialize(session, now: Time.now)
    @session = session
    @dir = Pulse.session_dir(session)
    @now = now
    @store = PulseStore.new(session)
  end

  # Read-only: every deadline crossed right now, each with a fingerprint that
  # changes when the underlying state does.
  def deadlines
    stalls + over_budget + pass_overrun + flat_state
  end

  # The 20 minute pass interval (backoff to 60) as a watcher deadline, so a
  # quiet run still gets its pass. Fingerprinted by the last pass.
  def interval_deadline
    cursor = @store.cursor
    return unless interval_due?(cursor)

    deadline('interval', 'interval', [ cursor['last_pass_at'] || cursor['engaged_at'], cursor['empty_passes'].to_i ])
  end

  # Returns {due, reasons[], cursor}. Read-only: the cursor update in the
  # result is applied by `commit` only once a pass is reserved and started, so
  # a failed reservation or spawn leaves every deadline due. Every input is
  # read once, so an event landing mid-check is reported by the next call.
  def run
    @events = read_events
    cursor = @store.cursor
    reported = Array(cursor['reported'])
    fresh = deadlines.reject { |d| reported.include?(d['fingerprint']) }
    new_events = @events.drop(cursor['consumed_events'].to_i).select { |e| e['event'] }
    reasons = fresh.map { |d| d['reason'] } + new_events.map { |e| "event:#{e['event']}" }
    reasons << 'state_changed' if state_digest != cursor['snapshot_digest'] && !(children.empty? && budgets.empty?)
    reasons << 'interval' if interval_due?(cursor)
    { 'due' => !reasons.empty?, 'reasons' => reasons, 'cursor' => pending(reported, fresh) }
  ensure
    @events = nil
  end

  def commit(result) = @store.advance_cursor(result.fetch('cursor'))

  def children
    events.select { |e| e['child_id'] }.group_by { |e| e['child_id'] }.transform_values do |list|
      latest = list.last
      since = list.reverse.take_while { |e| e['state_digest'] == latest['state_digest'] }.last
      { 'digest' => latest['state_digest'], 'changed_at' => Time.parse(since['at']), 'done' => latest['done'] }
    end
  end

  def budgets
    file = File.join(@dir, 'pulse_budgets.json')
    File.file?(file) ? Array(JSON.parse(File.read(file))) : []
  rescue JSON::ParserError
    []
  end

  def events = @events || read_events

  def read_events
    file = File.join(@dir, 'pulse_events.jsonl')
    return [] unless File.file?(file)

    File.readlines(file).filter_map do |line|
      row = JSON.parse(line)
      row if row.is_a?(Hash) && (row['child_id'].nil? || row['at'])
    rescue JSON::ParserError
      nil
    end
  end

  private

  def stalls
    children.filter_map do |id, child|
      next if child['done'] || @now - child['changed_at'] < STALL_S

      deadline('stall', "stall:#{id}", [ id, child['digest'], child['changed_at'].iso8601 ])
    end
  end

  def over_budget
    budgets.filter_map do |b|
      next if b['finished_at'] || @now - Time.parse(b['started_at']) < b['budget_s'].to_f * OVER_BUDGET

      deadline('over_budget', "over_budget:#{b['command']}", [ b['command'], b['started_at'] ])
    end
  end

  def pass_overrun
    file = File.join(@dir, 'pulse_pass.json')
    pass = JSON.parse(File.read(file)) if File.file?(file)
    return [] unless pass && !pass['finished_at'] &&
                     @now - Time.parse(pass['started_at']) >= Pulse.config['max_seconds_per_pass']

    [ deadline('pass_overrun', "pass_overrun:#{pass['task_id']}", [ pass['task_id'], pass['started_at'] ]).merge('task_id' => pass['task_id']) ]
  rescue JSON::ParserError
    []
  end

  # Unfinished budgeted commands and no signal for one full interval. Open
  # children are the stall check's job, so this covers work with no child to
  # stall. Deadline records the watcher itself wrote do not count as signal.
  def flat_state
    active = budgets.reject { |b| b['finished_at'] }
    return [] if active.empty? || children.any? { |_, c| !c['done'] }

    signals = events.reject { |e| e['fingerprint'] }.filter_map { |e| e['at'] } + active.map { |b| b['started_at'] }
    latest = signals.filter_map { |t| Time.parse(t) rescue nil }.max # rubocop:disable Style/RescueModifier
    return [] unless latest && @now - latest >= self.class.interval_s(@store.cursor['empty_passes'])

    [ deadline('flat_state', 'flat_state', [ latest.iso8601, *active.map { |b| b['command'] }.sort ]) ]
  end

  def deadline(kind, reason, parts) = { 'kind' => kind, 'reason' => reason, 'fingerprint' => Pulse.sha([ kind, *parts ].join('|')) }

  def interval_due?(cursor)
    last = cursor['last_pass_at'] || cursor['engaged_at']
    return false if last.nil? || !(cursor['active'] || !children.empty? || !budgets.empty?)

    @now - Time.parse(last) >= self.class.interval_s(cursor['empty_passes'])
  end

  def state_digest = Pulse.sha(JSON.generate([ children.transform_values { |c| c['digest'] }.sort, budgets ]))

  def pending(reported, fresh)
    { 'reported' => (reported + fresh.map { |d| d['fingerprint'] }).last(500), 'consumed_events' => events.size,
      'snapshot_digest' => state_digest, 'last_pass_at' => @now.utc.iso8601 }
  end
end

if __FILE__ == $PROGRAM_NAME
  opts = ARGV.reject { |arg| arg == '--json' }.each_slice(2).to_h { |flag, value| [ flag.delete_prefix('--'), value ] }
  abort 'usage: pulse_precheck.rb --session ID [--now ISO8601] [--commit true | --commit-result true] --json' unless opts['session']
  now = opts['now'] ? Time.parse(opts['now']) : Time.now
  check = PulsePrecheck.new(opts['session'], now: now)
  # `--commit-result true` applies the cursor of an earlier run (its JSON on
  # stdin), so events and deadlines that arrived since are not consumed unseen.
  result = opts['commit-result'] == 'true' ? JSON.parse($stdin.read) : check.run
  check.commit(result) if result['due'] && (opts['commit'] == 'true' || opts['commit-result'] == 'true')
  puts JSON.generate(result)
end
