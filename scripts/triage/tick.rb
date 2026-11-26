# frozen_string_literal: true

require 'json'
require 'time'
require 'socket'
require 'fileutils'
require 'securerandom'
require_relative 'paths'
require_relative 'sources'
require_relative 'publisher'
require_relative 'journal'
require_relative 'limits'
require_relative 'unit_cap'
require_relative 'liveness'
require_relative 'grant'
require_relative 'reconcile'
require_relative 'actions'
require_relative 'launcher'
require_relative 'reassign'
require_relative 'inbox_items'
require_relative '../leased_inbox'
require_relative '../ctx_expiry'

module Triage
  # One 15 minute tick (C9): deterministic, model-free and bounded under 60
  # seconds. It never waits on an action; a launch is persisted, then handed to
  # a detached one-shot job.
  #
  # Order: heartbeat, reconcile unfinished dispatches (C2), publish the report
  # and snapshot (C3), expire ctx pointers, upsert inbox items. Then, only when
  # no limit is active (C7), plan this host's repos in map order and launch:
  # every launch reserves a cap slot first (C5), carries its grant (C6), and is
  # journaled before the detached job starts (C2).
  #
  # `dry_run` reads everything and writes nothing: no heartbeat, journal, cap,
  # inbox, publish, archive or launch.
  class Tick
    BUDGET = 50

    Result = Struct.new(:skipped, :summary, keyword_init: true)

    def initialize(root: Paths.root, host: Paths.host, now: Time.now.utc, dry_run: false, sources: {}, journal: nil, cap: nil,
                   inbox: LeasedInbox.new, liveness: nil, grant: Grant.new(machine: host), detach: Launcher::Detach.method(:submit),
                   expirer: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, agents: nil,
                   acting_hosts: Actions::ACTING_HOSTS, lease_reader: Actions.method(:read_lease))
      @root = root
      @host = host
      @now = now
      @dry_run = dry_run
      @sources = sources
      @journal = journal || Journal.new(root: root, clock: -> { now })
      @cap = cap || UnitCap.new(root: root, clock: -> { now })
      @inbox = inbox
      @liveness = liveness || Liveness.new(host: Socket.gethostname)
      @grant = grant
      @detach = detach
      @expirer = expirer
      @clock = clock
      @started = clock.call
      @agents = agents || Liveness.method(:agents)
      @acting_hosts = acting_hosts
      @lease_reader = lease_reader
      @limits = Limits::Store.new(root: root)
    end

    def run
      return run_locked unless real?

      FileUtils.mkdir_p(@root)
      File.open(Paths.tick_lock_file(@root), File::RDWR | File::CREAT, 0o600) do |lock|
        # Overlapping ticks: the second finds the lock held and does nothing.
        return Result.new(skipped: 'overlap', summary: { 'skipped' => 'another tick holds the lock' }) unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        run_locked
      end
    end

    private

    def real? = !@dry_run

    def run_locked
      Heartbeat.write(Paths.heartbeat_dir(@root), @host || 'local', now: @now) if real?
      reconciled = reconcile
      report, generation = build_report
      expired = expire
      upsert_inbox(report)
      limit = @limits.active(now: @now)
      planned = limit || !@host ? [] : plan(report)
      launched = real? ? launch(planned) : planned.select(&:launch?).map { |action| action.to_h.merge('would_launch' => true) }
      escalate(planned) if real?
      Result.new(summary: summary(report, generation, reconciled, expired, limit, planned, launched))
    end

    def reconcile
      Reconcile.new(journal: @journal, liveness: @liveness, inbox: @inbox, now: @now, unlease: Launcher.method(:unlease),
                    agents: @agents, apply: real?).call.map(&:to_h)
    end

    # Publishes (writing report.json and the snapshot) or, in a dry run, only
    # builds the report from the same inputs.
    def build_report
      if real?
        done = Publisher.publish(root: @root, now: @now, **@sources)
        [ done.report, done.generation ]
      else
        inputs = Sources.collect(root: @root, now: @now, host: @host, **@sources)
        [ Report.new(**inputs).build, nil ]
      end
    end

    def expire
      return [] if over_budget?

      map = HostMap.load(Paths.hosts_file(@root))
      map.entries.select { |entry| entry.host == @host && entry.path && File.directory?(entry.path) }.map do |entry|
        expire_one(entry)
      end
    end

    def expire_one(entry)
      expirer = @expirer ? @expirer.call(entry.path) : CtxExpiry::Expirer.new(cwd: entry.path)
      plan = expirer.plan
      applied = real? ? expirer.apply(plan) : nil
      { 'repo' => entry.repo }.merge(CtxExpiry.summary(plan, applied: applied).slice('dry_run', 'counts'))
    rescue StandardError => e
      { 'repo' => entry.repo, 'error' => e.message[0, 160] }
    end

    def upsert_inbox(report)
      return unless real?

      report.fetch('decisions', []).each do |item|
        InboxItems.upsert(@inbox, kind: 'triage_decision', unit: item['refs'].to_s, finding: item['id'], title: item['subject'].to_s,
                                  data: { 'decision' => item })
      end
      report.fetch('findings', []).select { |f| f['code'] == 'host_stale' }.each do |finding|
        InboxItems.upsert(@inbox, kind: 'host_stale', unit: 'triage', finding: finding['detail'], title: finding['detail'])
      end
    end

    def plan(report)
      return [] if over_budget?

      map = HostMap.load(Paths.hosts_file(@root))
      Actions.new(host: @host, report: report, map: map, journal: @journal, liveness: @liveness, grant: @grant, now: @now,
                  stacks: Sources.stacks(@sources[:stack_root] || StackStore.root), acting_hosts: @acting_hosts, lease_reader: @lease_reader,
                  disabled: ->(repo) { File.exist?(Reassign.marker(repo, @root)) }).plan
    end

    # C5, C2, C9 in order: reserve, persist, then start detached. A refused
    # reservation launches nothing and is itself reported.
    def launch(planned)
      planned.select(&:launch?).filter_map do |action|
        next if over_budget?

        id = action_id
        slot = @cap.reserve(id)
        next { 'kind' => 'cap_refused', 'repo' => action.repo, 'unit' => action.unit, 'used' => slot.used, 'cap' => slot.cap } unless slot.granted

        @journal.append(dispatch_row(id, action, slot))
        submit(id, action)
      end
    end

    def submit(id, action)
      started = @detach.call(host: @host, action_id: id, root: @root)
      unless started
        @journal.append('type' => 'dead', 'action_id' => id, 'reason' => 'the detached job did not start')
        InboxItems.upsert(@inbox, kind: 'triage_escalation', unit: action.unit.to_s, finding: "submit_failed:#{id}",
                                  title: "could not start #{id}", body: 'the cap reservation stays consumed')
      end
      action.to_h.merge('action_id' => id, 'started' => started)
    end

    def dispatch_row(id, action, slot)
      { 'type' => 'dispatch', 'action_id' => id, 'host' => @host, 'repo' => action.repo, 'unit' => action.unit, 'verb' => action.verb,
        'path' => action.path, 'stack' => action.stack, 'session_id' => Launcher.new_session, 'grant' => action.grant.to_h,
        'reservation' => { 'day' => slot.day, 'used' => slot.used, 'cap' => slot.cap } }
    end

    def action_id = "#{@host}-#{@now.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(3)}"

    def escalate(planned)
      planned.select { |action| action.kind == 'escalate' }.each do |action|
        InboxItems.upsert(@inbox, kind: 'triage_escalation', unit: action.unit || action.repo, finding: action.finding.to_s,
                                  title: "#{action.repo}: #{action.reason}")
      end
      limit = @limits.active(now: @now)
      InboxItems.upsert(@inbox, kind: 'limited', unit: 'triage', finding: limit['kind'].to_s, title: "dispatch limited until #{limit['limited_until']}") if limit
    end

    def over_budget? = @clock.call - @started > BUDGET

    def summary(report, generation, reconciled, expired, limit, planned, launched)
      { 'dry_run' => @dry_run, 'host' => @host, 'generation' => generation, 'generated_at' => report['generated_at'],
        'units' => report['units'].size, 'findings' => report['findings'].size, 'limited' => limit,
        'cap' => @cap.status, 'reconciled' => reconciled, 'expired' => expired, 'over_budget' => over_budget?,
        'actions' => planned.map(&:to_h), 'launched' => launched }
    end
  end
end
