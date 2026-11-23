#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'English'
require 'time'
require 'fileutils'
require_relative 'pulse_store'
require_relative 'pulse_precheck'

# Orchestrator-level watcher (C1), the stack_watch.rb pattern: run it with
# run_in_background, it exits with a coded event on a stall or an overrun, the
# harness re-invokes the coordinator, and the coordinator re-arms it. Deadlines
# (stall, over-budget, pass overrun, flat state, the pass interval) exit at
# once; pushed events (PR, CI, gate, retry, phase, resource gate) are coalesced
# so a burst becomes one exit at least 5 minutes after the previous one.
class PulseWatch
  SETUP = 2
  TIMEOUT = 7
  CODES = { 'stall' => 10, 'over_budget' => 11, 'pass_overrun' => 12, 'flat_state' => 14, 'interval' => 15, 'events' => 16 }.freeze
  EVENTS = %w[pr_opened pr_merged pr_parked ci_red gate_verdict retry_started round_started phase_boundary
              resource_gate_fail run_result].freeze
  COALESCE_S = 300
  DISPATCH_DOWN = 13
  MAX_FAILED_STARTS = 3

  # `clock` returns a Time and `sleeper` takes seconds; both are injectable so
  # tests drive a fake clock.
  def initialize(session:, interval: 60, ttl: 86_400, clock: -> { Time.now }, sleeper: method(:sleep), prs: nil)
    @session = session
    @prs = prs
    @interval = interval.to_f
    @ttl = ttl.to_f
    @clock = clock
    @sleeper = sleeper
    @dir = Pulse.session_dir(session)
  end

  # Returns [exit_code, event_hash].
  def run
    started = @clock.call
    cleared = false
    loop do
      health = Health.new(@session, clock: @clock)
      health.beat(@interval)
      poll_prs
      check = PulsePrecheck.new(@session, now: @clock.call)
      hit = (check.deadlines + [ check.interval_deadline ].compact).find { |d| !announced?(d['fingerprint']) }
      batch = hit ? nil : pushed(health)
      # A start counts as good only after one successful poll.
      health.clear_failures unless cleared
      cleared = true
      return emit(hit, health) if hit
      return release(batch, health) if batch
      return [ TIMEOUT, { event: 'timeout', ttl: @ttl } ] if @clock.call - started >= @ttl

      @sleeper.call(@interval)
    end
  end

  # Watcher liveness (C1): a heartbeat file, a staleness test, and the count of
  # consecutive failed starts that ends in pulse-dispatch-down.
  class Health
    def initialize(session, clock: -> { Time.now }, alive: ->(pid) { alive?(pid) })
      @session = session
      @clock = clock
      @alive = alive
      @path = File.join(Pulse.session_dir(session), 'watcher.json')
    end

    def beat(interval)
      locked { write(read.merge('heartbeat_at' => @clock.call.utc.iso8601, 'pid' => Process.pid, 'interval' => interval)) }
    end

    def data = read

    def note(values) = locked { write(read.merge(values)) }

    def clear_failures = locked { write(read.except('failed_starts', 'outage_at')) }

    # ok, rearm (heartbeat older than 2 poll periods, or the pid is gone) or
    # dispatch_down (3 failed starts in a row).
    def check
      data = read
      return 'dispatch_down' if data['failed_starts'].to_i >= MAX_FAILED_STARTS
      return 'rearm' unless data['heartbeat_at'] && @alive.call(data['pid'])

      @clock.call - Time.parse(data['heartbeat_at']) > 2 * data['interval'].to_f ? 'rearm' : 'ok'
    end

    # Records a failed start; the third in a row records the P0 finding.
    def record_failed_start
      data = locked do
        read.tap do |d|
          d['failed_starts'] = d['failed_starts'].to_i + 1
          d['outage_at'] ||= @clock.call.utc.iso8601
          write(d)
        end
      end
      return unless data['failed_starts'] >= MAX_FAILED_STARTS

      PulseStore.new(@session).append_system(
        'kind' => 'integrity', 'severity' => 'P0', 'claim' => 'pulse-dispatch-down',
        'anchor' => "pulse-dispatch-down #{data['outage_at']}",
        'evidence' => "watcher failed to start #{data['failed_starts']} times in a row; pulse cannot see the run",
        'action_class' => 'report'
      )
    end

    private

    def alive?(pid)
      Process.kill(0, pid.to_i)
      true
    rescue SystemCallError, TypeError
      false
    end

    # A corrupt file reads as empty, which checks as rearm, never a crash.
    def read
      data = JSON.parse(File.read(@path)) if File.file?(@path)
      data.is_a?(Hash) ? data : {}
    rescue JSON::ParserError
      {}
    end

    def write(data)
      File.write("#{@path}.tmp", JSON.generate(data))
      File.rename("#{@path}.tmp", @path)
    end

    def locked(&)
      FileUtils.mkdir_p(File.dirname(@path))
      File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end
  end

  private

  # Announced already: a persisted event, or a deadline the pre-check reported.
  def announced?(fingerprint)
    PulsePrecheck.new(@session).events.any? { |e| e['fingerprint'] == fingerprint } ||
      Array(PulseStore.new(@session).cursor['reported']).include?(fingerprint)
  end

  # Persists the event so the pre-check counts it, then exits with its code.
  def emit(deadline, health)
    event = deadline.slice('kind', 'reason', 'fingerprint', 'task_id').merge('event' => deadline['kind'], 'at' => @clock.call.utc.iso8601)
    FileUtils.mkdir_p(@dir)
    File.open(File.join(@dir, 'pulse_events.jsonl'), 'a') { |file| file.puts(JSON.generate(event)) }
    [ CODES.fetch(deadline['kind']), event ]
  end

  # Pushed events the watcher has not announced, held until 5 minutes after the
  # previous event exit so a burst is one pass (the pre-check still counts each).
  def pushed(health)
    data = health.data
    rows = PulsePrecheck.new(@session).read_events
    consumed = [ data['announced_events'].to_i, PulseStore.new(@session).cursor['consumed_events'].to_i ].max
    fresh = rows.drop(consumed).select { |e| EVENTS.include?(e['event']) && !e['fingerprint'] }
    return if fresh.empty?

    last = data['last_event_exit_at']
    return if last && @clock.call - Time.parse(last) < COALESCE_S

    { 'events' => fresh.map { |e| e['event'] }, 'count' => rows.size }
  end

  def release(batch, health)
    health.note('announced_events' => batch['count'], 'last_event_exit_at' => @clock.call.utc.iso8601)
    [ CODES.fetch('events'), { 'event' => 'events', 'names' => batch['events'], 'at' => @clock.call.utc.iso8601 } ]
  end

  # PR and CI events from a poll of the forge, diffed against the last snapshot
  # (the first poll is a baseline and emits nothing). `prs` returns
  # [{number, state, head_sha, ci_red}].
  def poll_prs
    return unless @prs

    health = Health.new(@session, clock: @clock)
    seen = health.data['prs'] || {}
    # A forge failure keeps the last snapshot and never stops the local checks.
    now = begin
      @prs.call.to_h { |pr| [ pr['number'].to_s, pr ] }
    rescue StandardError
      return
    end
    return health.note('prs' => now) unless health.data.key?('prs')

    now.each do |number, pr|
      before = seen[number]
      names = before.nil? ? %w[pr_opened] : []
      names << 'pr_merged' if pr['state'] == 'MERGED' && before && before['state'] != 'MERGED'
      names << 'ci_red' if pr['ci_red'] && !(before && before['ci_red'] && before['head_sha'] == pr['head_sha'])
      names.each { |name| self.class.push(@session, name, { 'pr' => number.to_i, 'head_sha' => pr['head_sha'] }, clock: @clock) }
    end
    health.note('prs' => now)
  end

  def self.push(session, name, extra = {}, clock: -> { Time.now })
    raise ArgumentError, "unknown event #{name}" unless EVENTS.include?(name)

    dir = Pulse.session_dir(session)
    FileUtils.mkdir_p(dir)
    row = extra.compact.merge('event' => name, 'at' => clock.call.utc.iso8601)
    File.write(File.join(dir, 'pulse_events.jsonl'), "#{JSON.generate(row)}\n", mode: 'a')
    row
  end

  # `gh pr list` as the default PR source for `--repo owner/name`.
  def self.gh_prs(repo)
    out = IO.popen([ 'gh', 'pr', 'list', '--repo', repo, '--state', 'all', '--limit', '30', '--json', 'number,state,headRefOid,statusCheckRollup' ], &:read)
    raise 'gh pr list failed' unless $CHILD_STATUS.success?

    JSON.parse(out).map do |pr|
      { 'number' => pr['number'], 'state' => pr['state'], 'head_sha' => pr['headRefOid'],
        'ci_red' => Array(pr['statusCheckRollup']).any? { |c| %w[FAILURE ERROR TIMED_OUT CANCELLED].include?(c['conclusion'] || c['state']) } }
    end
  end

  # CLI: `pulse_watch.rb --session ID [--repo OWNER/NAME]`, `health`, `failed-start`, `emit --event NAME`.
  class CLI
    def self.run(argv, out: $stdout)
      sub = argv.first&.start_with?('--') ? nil : argv.shift
      opts = argv.each_slice(2).to_h { |flag, value| [ flag.delete_prefix('--'), value ] }
      raise ArgumentError, '--session is required' unless opts['session']

      case sub
      when 'health' then health(opts, out)
      when 'failed-start' then failed_start(opts, out)
      when 'emit' then emit(opts, out)
      else watch(opts, out)
      end
    rescue ArgumentError, TypeError => e
      out.puts(JSON.generate(event: 'setup_error', error: e.message))
      SETUP
    end

    def self.health(opts, out)
      out.puts(JSON.generate(state: Health.new(opts['session']).check))
      0
    end

    def self.failed_start(opts, out)
      health = Health.new(opts['session'])
      health.record_failed_start
      state = health.check
      out.puts(JSON.generate(state: state, event: (state == 'dispatch_down' ? 'pulse-dispatch-down' : nil)))
      state == 'dispatch_down' ? DISPATCH_DOWN : 0
    end

    def self.emit(opts, out)
      row = PulseWatch.push(opts['session'], opts.fetch('event') { raise ArgumentError, '--event is required' },
                            { 'pr' => opts['pr']&.to_i, 'head_sha' => opts['head-sha'], 'detail' => opts['detail'] })
      out.puts(JSON.generate(row))
      0
    end

    def self.watch(opts, out)
      prs = opts['repo'] ? -> { PulseWatch.gh_prs(opts['repo']) } : nil
      code, payload = PulseWatch.new(session: opts['session'], interval: Float(opts['interval'] || 60),
                                     ttl: Float(opts['ttl'] || 86_400), prs: prs).run
      out.puts(JSON.generate(payload))
      code
    end
  end
end

exit(PulseWatch::CLI.run(ARGV)) if __FILE__ == $PROGRAM_NAME
