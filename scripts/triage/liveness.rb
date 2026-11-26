# frozen_string_literal: true

require 'json'
require 'socket'
require_relative 'command'

module Triage
  # Tri-state owner liveness (C1): `alive`, `dead` or `unknown`. Only `dead`
  # acts; `unknown` escalates.
  #
  # Owner identity is host id + boot id + pid + pid start time + session id +
  # fence generation. `dead` needs authoritative evidence on the owning host:
  #   1. a recorded boot id that differs from the current one on the same
  #      machine proves the old process died with that boot; or
  #   2. same boot, the pid absent (or its start time changed: pid reuse), AND
  #      the session absent from a complete `claude agents --json --all`.
  # A command error, a partial listing, a remote owner, a missing identity
  # field or contradictory evidence (the pid is gone but the session is still
  # listed) is `unknown`. A pid that is alive with the recorded start time is
  # `alive` whatever the listing says.
  class Liveness
    Verdict = Struct.new(:state, :reason, keyword_init: true) do
      def dead? = state == 'dead'
      def alive? = state == 'alive'
      def unknown? = state == 'unknown'
    end

    Agents = Struct.new(:ok, :complete, :sessions, keyword_init: true)
    ABSENT = :absent
    TIMEOUT = 20

    # The OS boot identity: a random id on Linux, the boot timestamp on macOS.
    def self.current_boot_id(runner: Command.method(:run))
      linux = '/proc/sys/kernel/random/boot_id'
      return File.read(linux).strip if File.file?(linux)

      result = runner.call(%w[sysctl -n kern.boottime], 5)
      result.ok ? result.out.strip : nil
    rescue SystemCallError
      nil
    end

    # Start time of a pid as ps prints it, ABSENT when no such pid, nil when
    # the probe itself failed.
    def self.pid_start(pid, runner: Command.method(:run))
      result = runner.call([ 'ps', '-o', 'lstart=', '-p', pid.to_i.to_s ], 5)
      return nil if result.timed_out

      text = result.out.strip
      text.empty? ? (result.ok || result.err.to_s.strip.empty? ? ABSENT : nil) : text
    end

    # `claude agents --json --all`: complete only when the command succeeded
    # and parsed to the full list.
    def self.agents(runner: Command.method(:run), claude: 'claude')
      result = runner.call([ claude, 'agents', '--json', '--all' ], TIMEOUT)
      return Agents.new(ok: false, complete: false, sessions: []) unless result.ok

      parse_agents(result.out)
    rescue JSON::ParserError
      Agents.new(ok: false, complete: false, sessions: [])
    end

    def self.parse_agents(text)
      data = JSON.parse(text)
      rows = data.is_a?(Hash) ? data['agents'] : data
      return Agents.new(ok: false, complete: false, sessions: []) unless rows.is_a?(Array)

      partial = data.is_a?(Hash) && (data['truncated'] || data['partial'] || data['next'] || data['next_cursor'])
      sessions = rows.filter_map { |row| row.is_a?(Hash) ? (row['session_id'] || row['sessionId'] || row['id']) : nil }
      Agents.new(ok: true, complete: !partial, sessions: sessions)
    end

    def initialize(host:, boot_id: -> { self.class.current_boot_id }, pid_start: self.class.method(:pid_start),
                   agents: self.class.method(:agents))
      @host = host
      @boot_id = boot_id
      @pid_start = pid_start
      @agents = agents
    end

    # owner: { 'host', 'boot_id', 'pid', 'pid_start', 'session_id', 'fence' }
    def verdict(owner)
      reason = identity_problem(owner)
      return unknown(reason) if reason

      current = @boot_id.call
      return unknown('current boot id unavailable') if current.to_s.empty?
      return dead("boot id changed: #{owner['boot_id']} -> #{current}") if current != owner['boot_id']

      same_boot(owner)
    end

    private

    def identity_problem(owner)
      return 'no owner recorded' unless owner.is_a?(Hash)
      return "remote owner #{owner['host']}" unless owner['host'] == @host

      missing = %w[boot_id pid pid_start session_id].select { |key| owner[key].to_s.empty? }
      missing.empty? ? nil : "owner identity incomplete: #{missing.join(', ')}"
    end

    def same_boot(owner)
      started = @pid_start.call(owner['pid'])
      return unknown('pid probe failed') if started.nil?
      return alive('pid alive with the recorded start time') if started != ABSENT && started == owner['pid_start']

      gone = started == ABSENT ? 'pid absent' : 'pid start time changed (pid reuse)'
      listing = @agents.call
      return unknown("#{gone}; agent listing failed") unless listing.ok
      return unknown("#{gone}; agent listing partial") unless listing.complete
      return unknown("#{gone} but session #{owner['session_id']} is still listed") if listing.sessions.include?(owner['session_id'])

      dead("#{gone}; session absent from a complete listing")
    end

    def verdict_of(state, reason) = Verdict.new(state: state, reason: reason)
    def alive(reason) = verdict_of('alive', reason)
    def dead(reason) = verdict_of('dead', reason)
    def unknown(reason) = verdict_of('unknown', reason)
  end
end
