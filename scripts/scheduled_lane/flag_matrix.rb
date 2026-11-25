# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'time'
require_relative 'lane_config'
require_relative 'lane_run'

module ScheduledLane
  # Walks a set of feature flags one at a time through repo-declared adapter
  # commands: turn one on in a non-production env, run the lane, put it back.
  # Nothing here knows what a flag system is; every read and write is a command
  # the repo wrote (flip_cmd, revert_cmd, read_cmd, list_on_cmd, ledger_cmd).
  #
  # The safety properties, in the order they matter:
  #   - production, and any env in forbid_envs, is refused before anything runs;
  #   - a revert ledger row is written, in storage that is not this machine,
  #     before each flip, so a process that dies outright is found and undone
  #     by the next sweep;
  #   - the sweep runs first, before any early return, and restores every
  #     unreverted key to its recorded seed state (on or off);
  #   - never more than one flag on: list_on_cmd must print nothing before each
  #     flip, else the matrix aborts naming the stray keys;
  #   - any error after a flip goes to an explicit restore step (a lane failure,
  #     an exception, a timeout, a trapped TERM or INT). That is control flow
  #     plus a signal handler, not an ensure block, and the restore runs with
  #     the handler's interrupt held back so a second signal cannot cut it short;
  #   - reverts need authority (a decided dispatch or a standing receipt); a
  #     run without it only detects and reports.
  class FlagMatrix
    class Interrupted < StandardError; end
    class AdapterError < StandardError; end

    class StuckFlag < StandardError
      attr_reader :flag

      def initialize(flag, detail)
        @flag = flag
        super("#{flag} could not be restored: #{detail}")
      end
    end

    SIGNALS = %w[TERM INT].freeze
    SLACK_MINUTES = 10
    # Adapter commands one key can run: isolation read, seed read, ledger reads and writes,
    # flip and its confirmation, restore and its confirmation. Each gets an equal share of
    # revert_headroom_seconds as its timeout, so a hung adapter cannot outlast the headroom.
    ADAPTER_CALLS_PER_KEY = 16
    MIN_ADAPTER_TIMEOUT = 5
    STATES = %w[on off].freeze

    # `rows` has one entry per key; `iterations` the LaneRun::Iteration list.
    Result = Struct.new(:status, :failure_class, :notes, :rows, :iterations, :stuck_flag, keyword_init: true) do
      def pass? = status == 'pass'
    end

    # `run_lane` is called with an iteration number and returns a
    # LaneRun::Iteration. `receipt` is the id of the decision that gives this
    # run revert authority, nil for a detect-only run. `scrub` removes the
    # ledger credential from every command except the ledger's own.
    def initialize(lane:, runner:, env_name:, run_lane: nil, receipt: nil, job_timeout_minutes: nil, run_id: 'local',
                   sleeper: Kernel.method(:sleep), clock: -> { Time.now.utc }, environ: ENV)
      @lane = lane
      @matrix = lane.matrix
      @runner = runner
      @env_name = env_name
      @run_lane = run_lane
      @receipt = receipt.to_s.strip.empty? ? nil : receipt
      @job_timeout_minutes = job_timeout_minutes
      @run_id = run_id
      @sleeper = sleeper
      @clock = clock
      @environ = environ
      @rows = []
      @iterations = []
      @notes = []
      @signal = nil
      @ledger_ids = {}
    end

    # The matrix run: sweep, then each approved key alone.
    def run(keys)
      refusal = preflight(touched: true)
      return refusal if refusal

      with_signal_handlers { run_guarded(keys) }
    end

    # Nightly detection: read the ledger and the on-list, flip and revert
    # nothing, report what is wrong.
    def detect
      refusal = refuse_env
      return refusal if refusal

      pending, error = pending_rows
      return infra(error) if error

      stray, stray_error = on_keys
      return infra(stray_error) if stray_error

      findings = []
      findings << "unreverted ledger rows: #{pending.map { |row| row['key'] }.join(', ')}" unless pending.empty?
      findings << "flags on beyond the seeded defaults: #{stray.join(', ')}" unless stray.empty?
      return result('pass', nil) if findings.empty?

      infra(findings.join('; '), stuck: (pending.first || {})['key'])
    end

    # A standing-receipt recovery: the sweep alone.
    def recover
      refusal = preflight(touched: false)
      return refusal if refusal

      with_signal_handlers { guarded { recover_sweep } }
    end

    private

    def recover_sweep
      failure = sweep
      return failure if failure

      stray, error = on_keys
      return infra(error) if error
      return infra("flags still on that no ledger row explains: #{stray.join(', ')}") unless stray.empty?

      @notes << 'recovery sweep complete'
      result('pass', nil)
    end

    def run_guarded(keys)
      failure = guarded { sweep }
      return failure if failure

      guarded do
        cap = cap_problem(keys)
        next infra(cap) if cap

        if keys.empty?
          @notes << 'no touched flags'
          next result('pass', nil)
        end
        walk(keys)
      end || finish
    end

    # Runs the block, turning an Interrupted raised outside a key's own
    # restore step into an infra result. A returned Result stops the matrix.
    def guarded
      yield
    rescue Interrupted
      infra("interrupted by #{@signal || 'a signal'}; the next run's sweep restores anything still on")
    end

    def preflight(touched:)
      refusal = refuse_env
      return refusal if refusal
      return infra('a revert needs authority: pass --receipt <id> from a decided dispatch or a standing revert-to-seed receipt') unless @receipt

      cred = @matrix['ledger_credential_env']
      return infra("ledger credential #{cred} is not set; the ledger needs its write-scoped credential") if cred && @environ[cred].to_s.empty?
      return infra('--job-timeout-minutes is required for a matrix run') if touched && !@job_timeout_minutes

      nil
    end

    def refuse_env
      return infra('no env given; a matrix needs --env') if @env_name.to_s.empty?
      return infra("env '#{@env_name}' is not a valid name") unless @env_name.match?(ENV_PATTERN)
      return nil unless @lane.forbidden_envs.include?(@env_name.downcase)

      infra("refusing env '#{@env_name}': it is in forbid_envs (production is always forbidden)")
    end

    # Each lane run reads the deployed SHA twice, each read bounded by LaneRun::SHA_TIMEOUT_SECONDS.
    def sha_read_seconds = @lane.deployed_sha_cmd ? 2 * LaneRun::SHA_TIMEOUT_SECONDS : 0

    # The headroom, or what the adapter timeouts can actually use when their floor makes that more.
    def adapter_reserve_seconds = [ @matrix['revert_headroom_seconds'], ADAPTER_CALLS_PER_KEY * adapter_timeout ].max

    def cap_problem(keys)
      bad = keys.reject { |key| key.match?(FLAG_PATTERN) }
      return "unsafe flag key(s): #{bad.join(', ')}" unless bad.empty?
      return "#{keys.length} keys exceed max_flags #{@matrix['max_flags']}" if keys.length > @matrix['max_flags']

      needed = keys.length * (@matrix['settle_seconds'] + @lane.timeout_seconds + adapter_reserve_seconds + sha_read_seconds)
      allowed = (@job_timeout_minutes - SLACK_MINUTES) * 60
      return nil if needed <= allowed

      "matrix needs #{needed}s (#{keys.length} keys x settle, lane timeout, deployed SHA reads and revert headroom) but the job leaves #{allowed}s " \
        "(timeout #{@job_timeout_minutes} min minus #{SLACK_MINUTES} min slack)"
    end

    # --- recovery sweep -------------------------------------------------------

    # Returns nil when the ledger is clean (or was cleaned), else an infra Result.
    def sweep
      pending, error = pending_rows
      return infra(error) if error
      return nil if pending.empty?

      @notes << "sweep: restoring #{pending.map { |row| row['key'] }.join(', ')} to seed state"
      pending.each do |row|
        stuck = restore_pending(row)
        return stuck if stuck
      end
      nil
    end

    def restore_pending(row)
      confirmed = hold_signals { restore(row['key'], row['seed_state']) }
      unless confirmed[:ok]
        return infra("sweep could not restore #{row['key']} to #{row['seed_state']}: #{confirmed[:detail]}", stuck: row['key'])
      end

      error = hold_signals { mark_reverted(row['id']) }
      error ? infra("restored #{row['key']} but the ledger update failed: #{error}", stuck: row['key']) : nil
    end

    # --- per-key iteration -----------------------------------------------------

    def walk(keys)
      keys.each_with_index do |key, index|
        stop = run_key(key, index + 1)
        return stop if stop
      end
      nil
    end

    # Returns an infra Result to stop the matrix, else nil. Everything from the
    # ledger write to the restore confirmation runs here; the restore is
    # reached by ordinary control flow after the body, never by ensure.
    def run_key(key, iteration)
      row = { 'key' => key, 'seed_state' => nil, 'flip_attempted' => false, 'flip_ok' => false, 'lane' => nil, 'revert_ok' => nil, 'adapter_stdout' => '' }
      failure = nil
      hold_signals do
        begin
          Thread.handle_interrupt(Interrupted => :immediate) { flip_and_measure(key, iteration, row) }
        rescue Interrupted, StandardError => e
          failure = e
        end
        @rows << row
        failure = restore_step(key, row) || failure
      end
      stop_after(row, failure)
    end

    def flip_and_measure(key, iteration, row)
      stray, error = on_keys
      raise AdapterError, error if error
      raise AdapterError, "stray flags are on, nothing flipped: #{stray.join(', ')}" unless stray.empty?

      row['seed_state'] = read_state(key) || raise(AdapterError, "could not read #{key}")
      ledger_append(key, row['seed_state']) || raise(AdapterError, 'ledger write failed before the flip; nothing flipped')
      flip(key, row)
      @sleeper.call(@matrix['settle_seconds'])
      row['lane'] = measure(iteration)
    end

    def flip(key, row)
      row['flip_attempted'] = true
      outcome = adapter_call(LaneConfig.fill(@matrix['flip_cmd'], flag: key, env: @env_name), env: scrub)
      row['adapter_stdout'] = outcome.stdout.to_s.strip
      raise AdapterError, "flip_cmd failed for #{key}: #{outcome.summary}" unless outcome.ok?
      raise AdapterError, "#{key} did not read on after the flip" unless read_state(key) == 'on'

      row['flip_ok'] = true
    end

    def measure(iteration)
      current = @run_lane.call(iteration)
      @iterations << current
      current.to_h
    end

    # Restore the seed state and confirm it; returns an error to stop the matrix with.
    def restore_step(key, row)
      return nil unless row['flip_attempted']

      confirmed = restore(key, row['seed_state'])
      row['revert_ok'] = confirmed[:ok]
      row['adapter_stdout'] = [ row['adapter_stdout'], confirmed[:stdout] ].reject(&:empty?).join("\n")
      return StuckFlag.new(key, confirmed[:detail]) unless confirmed[:ok]

      error = mark_reverted(ledger_id(key))
      error ? StuckFlag.new(key, "restored, but the ledger update failed: #{error}") : nil
    end

    # The matrix stops on a stuck flag, an adapter error, a stray flag or an
    # interrupt; a plain lane failure does not stop it.
    def stop_after(row, failure)
      case failure
      when StuckFlag then infra("stopping the matrix: #{failure.message}", stuck: failure.flag)
      when Interrupted then infra("interrupted by #{@signal || 'a signal'} after restoring #{row['key']}")
      when nil then nil
      else
        row['lane'] ||= { 'status' => 'fail', 'class' => 'infra', 'notes' => [ failure.message ], 'cases' => [] }
        infra("#{row['key']}: #{failure.message}")
      end
    end

    # --- adapters ---------------------------------------------------------------

    def restore(key, seed_state)
      cmd = seed_state == 'on' ? @matrix['flip_cmd'] : @matrix['revert_cmd']
      outcome = adapter_call(LaneConfig.fill(cmd, flag: key, env: @env_name), env: scrub)
      state = read_state(key)
      return { ok: true, stdout: outcome.stdout.to_s.strip } if state == seed_state

      { ok: false, stdout: outcome.stdout.to_s.strip, detail: "read_cmd printed #{state.inspect}, wanted #{seed_state} (#{outcome.summary})" }
    rescue ConfigError => e
      { ok: false, stdout: '', detail: e.message }
    end

    def read_state(key)
      outcome = adapter_call(LaneConfig.fill(@matrix['read_cmd'], flag: key, env: @env_name), env: scrub)
      state = outcome.stdout.to_s.strip.downcase
      outcome.ok? && STATES.include?(state) ? state : nil
    end

    # [keys, nil] or [nil, error].
    def on_keys
      outcome = adapter_call(LaneConfig.fill(@matrix['list_on_cmd'], env: @env_name), env: scrub)
      return [ nil, "list_on_cmd failed: #{outcome.summary}" ] unless outcome.ok?

      [ outcome.stdout.to_s.lines.map(&:strip).reject(&:empty?), nil ]
    end

    # Every adapter command runs under a timeout, so a stalled flip, read or
    # ledger call ends in a classified failure and the restore step still runs.
    def adapter_call(cmd, **options)
      @runner.call(cmd, timeout: adapter_timeout, **options)
    end

    def adapter_timeout
      [ @matrix['revert_headroom_seconds'] / ADAPTER_CALLS_PER_KEY, MIN_ADAPTER_TIMEOUT ].max
    end

    def scrub = @lane.scrub_env

    # --- ledger -----------------------------------------------------------------

    # Unique per invocation: lane and env keep two lanes of one workflow run apart, the
    # nonce keeps a repeat of the same key under the same run id from closing the wrong row.
    def ledger_id(key) = (@ledger_ids[key] ||= "#{@run_id}:#{@lane.id}:#{@env_name}:#{key}:#{SecureRandom.hex(3)}")

    def ledger_get
      outcome = adapter_call("#{LaneConfig.fill(@matrix['ledger_cmd'], env: @env_name)} get")
      return [ nil, "ledger get failed: #{outcome.summary}" ] unless outcome.ok?

      text = outcome.stdout.to_s.strip
      return [ { 'rows' => [] }, nil ] if text.empty?

      doc = JSON.parse(text)
      return [ nil, 'ledger is not an object with a rows list' ] unless doc.is_a?(Hash) && doc['rows'].is_a?(Array)

      [ doc, nil ]
    rescue JSON::ParserError => e
      [ nil, "ledger is not valid JSON: #{e.message[0, 100]}" ]
    end

    def ledger_put(doc)
      outcome = adapter_call("#{LaneConfig.fill(@matrix['ledger_cmd'], env: @env_name)} put", stdin: JSON.generate(doc))
      outcome.ok? ? nil : "ledger put failed: #{outcome.summary}"
    end

    # [rows not yet reverted for this env, nil] or [nil, error].
    def pending_rows
      doc, error = ledger_get
      return [ nil, error ] if error

      [ doc['rows'].select { |row| row.is_a?(Hash) && row['env'] == @env_name && row['state'] != 'reverted' }, nil ]
    end

    def ledger_append(key, seed_state)
      doc, error = ledger_get
      return false if error

      doc['rows'] << { 'id' => ledger_id(key), 'key' => key, 'env' => @env_name, 'run_id' => @run_id, 'seed_state' => seed_state,
                       'state' => 'flipping', 'at' => @clock.call.iso8601 }
      ledger_put(doc).nil?
    end

    # nil on success, else the error text.
    def mark_reverted(id)
      doc, error = ledger_get
      return error if error

      row = doc['rows'].find { |entry| entry['id'] == id }
      return "no ledger row #{id}" unless row

      row.merge!('state' => 'reverted', 'reverted_at' => @clock.call.iso8601, 'receipt' => @receipt)
      ledger_put(doc)
    end

    # --- plumbing ---------------------------------------------------------------

    # Holds a signal's Interrupted back until the block ends, so a restore is
    # never cut short. The held interrupt is delivered when the block exits.
    def hold_signals(&)
      Thread.handle_interrupt(Interrupted => :never, &)
    end

    def with_signal_handlers
      previous = SIGNALS.to_h do |name|
        [ name, Signal.trap(name) do
          @signal = name
          Thread.main.raise(Interrupted, "interrupted by #{name}")
        end ]
      end
      yield
    ensure
      previous&.each { |name, handler| Signal.trap(name, handler || 'DEFAULT') }
    end

    def result(status, failure_class)
      Result.new(status: status, failure_class: failure_class, notes: @notes, rows: @rows, iterations: @iterations)
    end

    def infra(note, stuck: nil)
      @notes << note
      Result.new(status: 'fail', failure_class: 'infra', notes: @notes, rows: @rows, iterations: @iterations, stuck_flag: stuck)
    end

    def finish
      failed = @iterations.map(&:verdict).reject(&:pass?)
      return result('pass', nil) if failed.empty?

      result('fail', failed.any? { |verdict| verdict.failure_class == 'infra' } ? 'infra' : 'app')
    end
  end
end
