#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'
require_relative 'pulse_store'
require_relative 'pulse_precheck'

# Orchestrator-level watcher (C1), the stack_watch.rb pattern: run it with
# run_in_background, it exits with a coded event on a stall or an overrun, the
# harness re-invokes the coordinator, and the coordinator re-arms it. Phase 1
# covers stall, over-budget and pass-overrun plus watcher health; the full
# event set lands later.
class PulseWatch
  SETUP = 2
  TIMEOUT = 7
  CODES = { 'stall' => 10, 'over_budget' => 11, 'pass_overrun' => 12 }.freeze
  DISPATCH_DOWN = 13
  MAX_FAILED_STARTS = 3

  # `clock` returns a Time and `sleeper` takes seconds; both are injectable so
  # tests drive a fake clock.
  def initialize(session:, interval: 60, ttl: 86_400, clock: -> { Time.now }, sleeper: method(:sleep))
    @session = session
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
      hit = PulsePrecheck.new(@session, now: @clock.call).deadlines.find { |d| !announced?(d['fingerprint']) }
      # A start counts as good only after one successful poll.
      health.clear_failures unless cleared
      cleared = true
      return emit(hit) if hit
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
  def emit(deadline)
    event = deadline.slice('kind', 'reason', 'fingerprint', 'task_id').merge('event' => deadline['kind'], 'at' => @clock.call.utc.iso8601)
    FileUtils.mkdir_p(@dir)
    File.open(File.join(@dir, 'pulse_events.jsonl'), 'a') { |file| file.puts(JSON.generate(event)) }
    [ CODES.fetch(deadline['kind']), event ]
  end

  # CLI: `pulse_watch.rb --session ID`, `health --session ID`, `failed-start --session ID`.
  class CLI
    def self.run(argv, out: $stdout)
      sub = argv.first&.start_with?('--') ? nil : argv.shift
      opts = argv.each_slice(2).to_h { |flag, value| [ flag.delete_prefix('--'), value ] }
      raise ArgumentError, '--session is required' unless opts['session']

      case sub
      when 'health' then health(opts, out)
      when 'failed-start' then failed_start(opts, out)
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

    def self.watch(opts, out)
      code, payload = PulseWatch.new(session: opts['session'], interval: Float(opts['interval'] || 60),
                                     ttl: Float(opts['ttl'] || 86_400)).run
      out.puts(JSON.generate(payload))
      code
    end
  end
end

exit(PulseWatch::CLI.run(ARGV)) if __FILE__ == $PROGRAM_NAME
