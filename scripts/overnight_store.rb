#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'
require 'digest'
require 'socket'
require 'securerandom'
require_relative 'stack_store'

# Durable state of one cf:overnight run: state.json (atomic temp file plus
# rename), journal.jsonl (append-only, fsync per line), policy.json (frozen
# snapshot plus its sha256) and lease.json (fenced lease).
#
# Layout: ~/.claude/cf/overnight/<repo_dir>/<run-id>/. The repo segment reuses
# StackStore.repo_dir, and the lease reuses #448's LEASE primitives (exclusive
# publish via link(2), a flock around every read-check-replace, an incomplete
# holder reads as held). It adds a monotonically increasing fencing token:
# every mutation carries the token, and a write with a stale token is refused.
#
# Unlike StackStore, a corrupt state or journal is never read as absent. It
# blocks every mutation and only a read-only report runs; nothing is moved
# aside.
#
# Mutation is disabled until the enablement gate: every executing path calls
# OvernightStore.assert_execute_enabled!, which refuses while the constant
# below is false. Only --dry-run and fake-provider tests run before then.
class OvernightStore
  OVERNIGHT_EXECUTE_ENABLED = false

  LEASE_TTL = 900
  PHASES = %w[planned dispatched observed-complete uncertain].freeze
  ACTION_ID = /\A[A-Za-z0-9._-]+:[A-Za-z0-9._-]+:\d+\z/

  # The dispatch protocol, one row per side-effect kind. `idempotency` is how
  # a repeated request is made harmless (the key persisted with intent before
  # the request); `lookup` is how resume finds the outcome by external id.
  # A kind with neither cannot be retried after an uncertain dispatch: the
  # unit goes to handed-over. skills/overnight/reference/dispatch.md renders
  # this table and test/overnight_skill_test.rb keeps the two in step.
  DISPATCH = {
    'push' => { idempotency: 'expected remote head sha', lookup: 'git ls-remote' },
    'pr-open' => { idempotency: 'head branch (one open PR per head)', lookup: 'gh pr list --head' },
    'merge' => { idempotency: 'gh pr merge --match-head-commit', lookup: 'gh pr view --json state,mergeCommit' },
    'tag-push' => { idempotency: 'tag name bound to one sha', lookup: 'git ls-remote --tags' },
    'flag-change' => { idempotency: 'compare-and-set where the adapter offers it', lookup: 'flags adapter read-back' },
    'deploy-trigger' => { idempotency: 'none', lookup: 'gh run list --workflow --commit' },
    'backup' => { idempotency: 'correlation key in the dump file name', lookup: 'dump file plus checksum' },
    'snapshot' => { idempotency: 'correlation key in the snapshot name', lookup: 'provider snapshot list' },
    'window' => { idempotency: 'open or close is a state set', lookup: 'maintenance command status' },
    'destructive-write' => { idempotency: 'none', lookup: 'none' },
    'paid-call' => { idempotency: 'content key cache', lookup: 'spend.json by reservation id' }
  }.freeze

  class Error < StandardError; end
  # State or journal is unreadable: mutations blocked, report only.
  class Corrupt < Error; end
  # The writer's fencing token is not the current lease's.
  class StaleToken < Error; end
  # Executing path called while OVERNIGHT_EXECUTE_ENABLED is false.
  class Disabled < Error; end
  # Several unfinished runs and none named.
  class Ambiguous < Error; end
  # Lease or target lock held by someone else.
  class Held < Error
    attr_reader :holder

    def initialize(message, holder = nil)
      @holder = holder
      super(message)
    end
  end

  def self.execute_enabled? = OVERNIGHT_EXECUTE_ENABLED

  def self.assert_execute_enabled!
    return if execute_enabled?

    raise Disabled, 'overnight execution is disabled (OVERNIGHT_EXECUTE_ENABLED is false); use --dry-run'
  end

  def self.root = File.join(Dir.home, '.claude', 'cf', 'overnight')

  def self.repo_base(repo_id) = File.join(root, StackStore.repo_dir(repo_id))

  def self.run_ids(repo_id)
    Dir.glob(File.join(repo_base(repo_id), '*', 'state.json')).map { |f| File.basename(File.dirname(f)) }.sort
  end

  # Unfinished runs for this repo. A run whose state cannot be read counts as
  # unfinished: it is never skipped silently.
  def self.unfinished(repo_id)
    run_ids(repo_id).reject do |id|
      new(repo_id, id).state['finished']
    rescue Corrupt
      false
    end
  end

  # `resume` with an id picks that run; without one it picks the only
  # unfinished run, nil when there is none, and refuses when there are several.
  def self.select(repo_id, run_id = nil)
    return new(repo_id, run_id) if run_id

    open = unfinished(repo_id)
    raise Ambiguous, "several unfinished runs, name one: #{open.join(', ')}" if open.size > 1

    open.empty? ? nil : new(repo_id, open.first)
  end

  def self.new_run_id(now = Time.now.utc) = "#{now.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(3)}"

  attr_reader :repo_id, :run_id
  # Tests inject a clock to expire a lease between two writes.
  attr_writer :clock

  def clock = @clock || -> { Time.now.utc }

  def initialize(repo_id, run_id)
    @repo_id = repo_id.to_s
    @run_id = StackStore.segment(run_id)
    raise Error, 'repo id and run id are required' if @repo_id.empty? || @run_id.empty?
  end

  def dir = File.join(OvernightStore.repo_base(@repo_id), @run_id)
  def state_path = File.join(dir, 'state.json')
  def journal_path = File.join(dir, 'journal.jsonl')
  def policy_path = File.join(dir, 'policy.json')
  def lease_path = File.join(dir, 'lease.json')

  # Creates the run. Needs no lease: nothing else can know the run id yet.
  def create(repo:, units: [])
    raise Error, "run #{@run_id} already exists" if File.exist?(state_path)

    FileUtils.mkdir_p(dir)
    write_atomic(state_path, 'run_id' => @run_id, 'repo' => repo.to_s, 'units' => units, 'finished' => false)
    File.write(journal_path, '') unless File.exist?(journal_path)
    state
  end

  def state
    return {} unless File.exist?(state_path)

    data = JSON.parse(File.read(state_path))
    raise Corrupt, "#{state_path} is not a JSON object" unless data.is_a?(Hash)

    data
  rescue JSON::ParserError, SystemCallError => e
    raise Corrupt, "#{state_path}: #{e.message}"
  end

  def journal
    return [] unless File.exist?(journal_path)

    File.readlines(journal_path, chomp: true).each_with_index.map do |line, index|
      record = JSON.parse(line)
      raise Corrupt, "#{journal_path}:#{index + 1} is not a JSON object" unless record.is_a?(Hash)

      record
    end
  rescue JSON::ParserError, SystemCallError => e
    raise Corrupt, "#{journal_path}: #{e.message}"
  end

  # True when the state or journal cannot be read; every mutation refuses.
  def mutations_blocked?
    state
    journal
    false
  rescue Corrupt
    true
  end

  # Folds the journal into the latest record per action id, in journal order.
  def actions
    journal.each_with_object({}) do |record, acc|
      acc[record['id']] = (acc[record['id']] || {}).merge(record)
    end
  end

  # Actions resume must reconcile before anything else: intent persisted
  # (planned) or request sent (dispatched) or uncertain, never observed.
  def nonterminal
    actions.values.reject { |action| action['phase'] == 'observed-complete' }
  end

  # Units an unreconciled action blocks: the kind has no idempotency and no
  # lookup, so resume cannot learn the outcome and must not retry. A planned
  # action counts: the request may have been accepted before the response
  # was persisted.
  def blocked_units
    nonterminal.reject { |a| reconcilable?(a['kind']) }
               .map { |a| a['id'].split(':').first }.uniq.sort
  end

  def reconcilable?(kind)
    row = DISPATCH[kind.to_s]
    row && (row[:idempotency] != 'none' || row[:lookup] != 'none')
  end

  # planned: intent plus the idempotency key, persisted before the request.
  def plan_action(id, kind:, token:, key: nil, detail: {})
    raise Error, "unknown action kind #{kind}" unless DISPATCH.key?(kind.to_s)

    append(id, 'planned', token, 'kind' => kind.to_s, 'key' => key || "#{@run_id}:#{id}", 'detail' => detail) do |prior|
      raise Error, "#{id} is already #{prior['phase']}" if prior
    end
  end

  # dispatched: the response, with external ids (PR number, tag, run id).
  def dispatch_action(id, token:, external: {})
    append(id, 'dispatched', token, 'external' => external) do |prior|
      raise Error, "#{id} was never planned" unless prior
      raise Error, "#{id} is already #{prior['phase']}" unless %w[planned uncertain].include?(prior['phase'])
    end
  end

  # observed-complete: the outcome confirmed with evidence. Also the record
  # resume writes when reconciliation finds the outcome.
  def observe_action(id, token:, evidence: {}, reconcile: false)
    append(id, 'observed-complete', token, 'evidence' => evidence, 'reconciled' => reconcile, lease_mode: :any) do |prior|
      raise Error, "#{id} was never planned" unless prior
      raise Error, "#{id} is already observed-complete" if prior['phase'] == 'observed-complete'
    end
  end

  # uncertain: the request may or may not have reached the target (a crash,
  # a cancellation, a lost response). Never treated as complete.
  def mark_uncertain(id, token:, reason:)
    append(id, 'uncertain', token, 'reason' => reason.to_s, lease_mode: :any) do |prior|
      raise Error, "#{id} was never planned" unless prior
      raise Error, "#{id} is already observed-complete" if prior['phase'] == 'observed-complete'
    end
  end

  def update_state(token:, &block)
    with_lock do
      check_token!(token, :full)
      data = state
      block.call(data)
      write_atomic(state_path, data)
      data
    end
  end

  # Freezes the manifest plus answers. Returns the sha256 recorded with it.
  def freeze_policy(policy, token:)
    with_lock do
      check_token!(token, :full)
      raise Error, 'policy is already frozen for this run' if File.exist?(policy_path)

      hash = OvernightStore.policy_hash(policy)
      write_atomic(policy_path, 'sha256' => hash, 'policy' => policy)
      hash
    end
  end

  def policy
    return nil unless File.exist?(policy_path)

    JSON.parse(File.read(policy_path))
  rescue JSON::ParserError, SystemCallError => e
    raise Corrupt, "#{policy_path}: #{e.message}"
  end

  def self.policy_hash(policy) = Digest::SHA256.hexdigest(canonical_json(policy))

  def self.canonical_json(value)
    case value
    when Hash then "{#{value.map { |k, v| [ k.to_s, v ] }.sort_by(&:first).map { |k, v| "#{k.to_json}:#{canonical_json(v)}" }.join(',')}}"
    when Array then "[#{value.map { |v| canonical_json(v) }.join(',')}]"
    else value.to_json
    end
  end

  # Fenced lease. A fresh lease takes token 1; a takeover after expiry takes
  # the next token. The same session re-acquiring keeps its token and mode.
  # A new holder facing any nonterminal action (a planned one may already
  # have reached the remote) is granted reconcile mode only: it may record
  # observed outcomes and uncertainty, but plans and dispatches nothing until
  # every nonterminal action is reconciled. A request found never sent is
  # recorded observed-complete with that evidence and retried as the next
  # attempt id.
  def acquire_lease(session:, now: clock.call)
    with_lock do
      raise Corrupt, 'state or journal is corrupt; mutations blocked' if mutations_blocked?

      holder = StackStore.holder(lease_path)
      if holder.is_a?(Hash) && holder['session_id'] == session.to_s && !expired?(holder, now)
        token = holder['token']
        mode = holder['mode']
      elsif holder.nil? || expired?(holder, now)
        token = [ holder.is_a?(Hash) ? holder['token'].to_i : 0, last_token ].max + 1
        mode = reconciled? ? 'full' : 'reconcile'
      else
        raise Held.new("lease held by session #{holder.is_a?(Hash) ? holder['session_id'] : 'unknown'}",
                       holder.is_a?(Hash) ? holder : nil)
      end
      lease = { 'slug' => @run_id, 'session_id' => session.to_s, 'host' => Socket.gethostname, 'token' => token,
                'mode' => mode, 'expires_at' => (now + LEASE_TTL).iso8601 }
      write_atomic(lease_path, lease)
      remember_token(token)
      lease
    end
  end

  def renew_lease(token:, now: clock.call)
    with_lock do
      holder = check_token!(token, :any, now)
      holder['expires_at'] = (now + LEASE_TTL).iso8601
      write_atomic(lease_path, holder)
      holder
    end
  end

  def release_lease(token:)
    with_lock do
      check_token!(token, :any)
      FileUtils.rm_f(lease_path)
      { 'released' => token }
    end
  end

  def lease = (h = StackStore.holder(lease_path)).is_a?(Hash) ? h : nil

  # Ownership lock: the repo's ACTIVE claim, shared with cf:sweep stack mode
  # (#448), so an overnight run and a sweep never land into one repo at once,
  # plus a per-target lock so a second run id on the same deployment target
  # is refused.
  def claim_target(target:)
    StackStore.new(@repo_id, "overnight-#{@run_id}").claim(source: 'overnight')
    file = target_lock_path(target)
    data = { 'slug' => @run_id, 'target' => target.to_s, 'claimed_at' => clock.call.iso8601 }
    return data if StackStore.publish_exclusive(file, data)

    holder = StackStore.holder(file)
    return holder if holder.is_a?(Hash) && holder['slug'] == @run_id

    raise Held.new("target #{target} is owned by run #{holder.is_a?(Hash) ? holder['slug'] : 'unknown'}",
                   holder.is_a?(Hash) ? holder : nil)
  rescue StackStore::Held => e
    raise Held.new("repo is claimed by #{e.holder ? e.holder['slug'] : 'an incomplete holder'}", e.holder)
  end

  def release_target(target:)
    file = target_lock_path(target)
    holder = StackStore.holder(file)
    FileUtils.rm_f(file) if holder.is_a?(Hash) && holder['slug'] == @run_id
    StackStore.new(@repo_id, "overnight-#{@run_id}").release
  end

  def target_lock_path(target) = File.join(OvernightStore.repo_base(@repo_id), "TARGET-#{StackStore.segment(target)}")

  private

  def append(id, phase, token, fields)
    lease_mode = fields.delete(:lease_mode) || :full
    raise Error, "action id must read <unit>:<step>:<attempt>, got #{id.inspect}" unless id.to_s.match?(ACTION_ID)

    with_lock do
      check_token!(token, lease_mode)
      yield actions[id.to_s]
      record = { 'id' => id.to_s, 'phase' => phase, 'token' => token, 'at' => clock.call.iso8601 }.merge(fields)
      File.open(journal_path, 'a') do |io|
        io.write("#{JSON.generate(record)}\n")
        io.flush
        io.fsync
      end
      record
    end
  end

  # Refuses unless `token` is the live lease's. `need` :full also refuses a
  # reconcile-mode lease that still has nonterminal dispatches.
  def check_token!(token, need, now = clock.call)
    raise Corrupt, 'state or journal is corrupt; mutations blocked' if mutations_blocked?

    holder = StackStore.holder(lease_path)
    raise StaleToken, 'no lease held' unless holder.is_a?(Hash)
    raise StaleToken, "token #{token} is stale (current #{holder['token']})" unless holder['token'] == token
    raise StaleToken, "lease token #{token} has expired" if expired?(holder, now)

    if need == :full && holder['mode'] == 'reconcile'
      raise Error, 'reconcile every nonterminal action before planning more' unless reconciled?

      holder['mode'] = 'full'
      write_atomic(lease_path, holder)
    end
    holder
  end

  def reconciled? = nonterminal.empty?

  # An incomplete lease file reads as held until it is LEASE_TTL old, as in
  # StackStore.
  def expired?(holder, now)
    return File.mtime(lease_path) < now - LEASE_TTL if holder == :incomplete
    return true unless holder.is_a?(Hash)

    Time.parse(holder['expires_at'].to_s) < now
  rescue ArgumentError, SystemCallError
    true
  end

  # The highest token ever issued survives lease release, so a token never
  # repeats for one run.
  def last_token = File.exist?(token_path) ? File.read(token_path).to_i : 0
  def remember_token(token)
    File.write(token_path, token.to_s) if token > last_token
  end
  def token_path = File.join(dir, 'lease.token')

  def with_lock
    FileUtils.mkdir_p(dir)
    File.open(File.join(dir, '.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      yield
    end
  end

  def write_atomic(file, data)
    tmp = "#{file}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp"
    File.open(tmp, 'w') do |io|
      io.write(JSON.pretty_generate(data))
      io.flush
      io.fsync
    end
    File.rename(tmp, file)
  ensure
    FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
  end
end

if $PROGRAM_NAME == __FILE__
  # Read-only CLI: list runs for a repo id, or show one run's reconcile view.
  cmd, repo_id, run_id = ARGV
  begin
    case cmd
    when 'list'
      puts JSON.pretty_generate(OvernightStore.run_ids(repo_id.to_s).map { |id| { 'run_id' => id } })
    when 'show'
      store = OvernightStore.select(repo_id.to_s, run_id)
      abort 'no unfinished run' unless store
      puts JSON.pretty_generate('run_id' => store.run_id, 'blocked' => store.mutations_blocked?,
                                'nonterminal' => store.nonterminal, 'blocked_units' => store.blocked_units)
    else
      warn 'usage: overnight_store.rb list <repo_id> | show <repo_id> [run_id]'
      exit 2
    end
  rescue OvernightStore::Error => e
    warn e.message
    exit 1
  end
end
