# frozen_string_literal: true

require 'time'
require_relative 'paths'
require_relative 'grant'
require_relative 'journal'
require_relative 'launcher'
require_relative '../stack_store'

module Triage
  # Decides, per repo pinned to this host in map order, what the tick does next.
  # Pure planning: nothing here launches, reserves or writes.
  #
  #   report-only   the host is not an acting host (the spike left the vm
  #                 report-only), the repo has no checkout path, or dispatch is
  #                 disabled for it by a reassignment (C8)
  #   escalate      the host map and a snapshot disagree on the assignment, or a
  #                 stalled stack's owner is `unknown` (C1), or the recovery is
  #                 not a reversible verb
  #   skip          an unfinished dispatch already holds the repo (C4: one
  #                 active unit per repo)
  #   propose       a launch is warranted but no autopilot window covers it
  #   recover       a `dead` owner: takeover, redrive or rewatch, chosen by
  #                 StackStore.resume_action, and nothing else
  #   start_next    the first eligible unit (C4 order), inside a window
  #
  # Elapsed time never acts: a stale lease heartbeat only makes a stack worth
  # inspecting; the liveness verdict decides.
  class Actions
    # The spike set vmActs false (no unattended OAuth login on the vm): until a
    # later spike proves it, only the mini acts and the vm reports.
    ACTING_HOSTS = %w[mini].freeze
    RECOVER_VERBS = { 'drive' => 'takeover', 'redrive' => 'redrive', 'rewatch' => 'rewatch' }.freeze

    Action = Struct.new(:kind, :verb, :repo, :unit, :reason, :path, :stack, :grant, :finding, keyword_init: true) do
      def launch? = %w[start_next recover].include?(kind)

      def to_h
        { 'kind' => kind, 'verb' => verb, 'repo' => repo, 'unit' => unit, 'reason' => reason, 'path' => path, 'stack' => stack,
          'grant' => grant&.to_h, 'finding' => finding }.compact
      end
    end

    def initialize(host:, report:, map:, journal:, liveness:, grant:, now:, stacks:, disabled: ->(_repo) { false },
                   acting_hosts: ACTING_HOSTS, lease_reader: self.class.method(:read_lease))
      @host = host
      @report = report
      @map = map
      @journal = journal
      @liveness = liveness
      @grant = grant
      @now = now
      @stacks = stacks
      @disabled = disabled
      @acting_hosts = acting_hosts
      @lease_reader = lease_reader
    end

    def self.read_lease(record)
      holder = StackStore.holder(StackStore.new(record['repo'], record['slug']).lease_path)
      holder.is_a?(Hash) ? holder : nil
    end

    def plan
      return [] unless @host

      @map.entries.select { |entry| entry.host == @host }.map { |entry| plan_repo(entry) }
    end

    private

    def plan_repo(entry)
      repo = entry.repo
      return note('report_only', repo, "#{@host} is not an acting host") unless @acting_hosts.include?(@host)
      return note('report_only', repo, 'no path in hosts.yml') unless entry.path
      return note('report_only', repo, 'dispatch disabled for reassignment') if @disabled.call(repo)

      mismatch = mismatch(repo)
      return escalate(repo, nil, 'assignment_mismatch', mismatch) if mismatch
      return note('skip', repo, 'an unfinished dispatch holds the repo') if @journal.unfinished.any? { |d| d.repo == repo }

      recover(entry) || start_next(entry) || note('idle', repo, 'nothing eligible')
    end

    def mismatch(repo)
      @report.fetch('findings', []).find { |f| f['code'] == 'assignment_mismatch' && f['detail'].to_s.start_with?("#{repo}:") }&.fetch('detail')
    end

    # --- recovery ----------------------------------------------------------

    def recover(entry)
      stalled(entry.repo).each do |record|
        action = recover_one(entry, record)
        return action if action
      end
      nil
    end

    def stalled(repo)
      @stacks.select { |record| record['repo'] == repo && !StackStore.finished?(record) && stalled?(record) }
             .sort_by { |record| record['slug'].to_s }
    end

    # Worth inspecting: someone was working it (preparing or handed off) and
    # its lease is gone or its heartbeat is past the TTL. Inspection is not
    # action; the verdict below decides.
    def stalled?(record)
      head = StackStore.current_pr(record)
      return false unless head && %w[preparing handed_off].include?(head['state'])

      holder = @lease_reader.call(record)
      holder.nil? || Time.parse(holder['heartbeat_at'].to_s) < @now - StackStore::LEASE_TTL
    rescue ArgumentError
      true
    end

    def recover_one(entry, record)
      unit = "#{entry.repo}#stack/#{record['slug']}"
      verdict = @liveness.verdict(owner(record))
      return nil if verdict.alive?
      return escalate(entry.repo, unit, "owner_unknown:#{record['slug']}", "owner is unknown: #{verdict.reason}") if verdict.unknown?

      verb = RECOVER_VERBS[resume(record, unit)]
      return escalate(entry.repo, unit, "recover_refused:#{record['slug']}", "not a reversible verb: #{resume(record, unit)}") unless verb

      launch('recover', verb, entry, unit, "owner dead: #{verdict.reason}",
             'repo_id' => record['repo'], 'slug' => record['slug'])
    end

    def resume(record, unit)
      head = StackStore.current_pr(record)
      live = @report.fetch('units', []).find { |row| row['unit'] == unit }&.fetch('prs', [])&.find { |pr| pr['number'] == head['number'] }
      StackStore.resume_action(head['state'], live && live['state'])
    end

    # The owner identity C1 needs. A lease written by a triage dispatch has its
    # handshake (boot id, pid start time); any other holder lacks them, which
    # reads as `unknown`, never as `dead`.
    def owner(record)
      holder = @lease_reader.call(record)
      return nil unless holder

      shake = @journal.dispatches.find { |d| d.session == holder['session_id'] }&.handshake
      return { 'host' => holder['host'], 'pid' => holder['pid'], 'session_id' => holder['session_id'] } unless shake

      { 'host' => shake['host'], 'boot_id' => shake['boot_id'], 'pid' => shake['pid'], 'pid_start' => shake['pid_start'],
        'session_id' => shake['session_id'], 'fence' => shake['fence'] }
    end

    # --- start_next --------------------------------------------------------

    def start_next(entry)
      id = @report.fetch('eligible', []).find { |unit| unit.start_with?("#{entry.repo}#") }
      return nil unless id

      launch('start_next', 'start_next', entry, id, 'first eligible unit', nil)
    end

    def launch(kind, verb, entry, unit, reason, stack)
      grant = @grant.for(repo: entry.repo, path: entry.path, unit: unit, verb: verb, now: @now)
      return Action.new(kind: 'propose', verb: verb, repo: entry.repo, unit: unit, reason: "#{reason}; no active autopilot window", path: entry.path) unless grant

      Action.new(kind: kind, verb: verb, repo: entry.repo, unit: unit, reason: reason, path: entry.path, stack: stack, grant: grant)
    end

    def note(kind, repo, reason) = Action.new(kind: kind, repo: repo, reason: reason)

    def escalate(repo, unit, finding, reason)
      Action.new(kind: 'escalate', repo: repo, unit: unit, reason: reason, finding: finding)
    end
  end
end
