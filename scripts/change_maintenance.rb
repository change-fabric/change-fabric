#!/usr/bin/env ruby
# frozen_string_literal: true

require 'date'
require 'json'
require 'open3'
require 'optparse'
require 'set'
require 'time'
require_relative 'change_backup'
require_relative 'change_prod_envelope'
require_relative 'change_prod_store'

# Maintenance windows for the bounded prod runner (spec 0.31.0).
#
# Three jobs. Window evaluation: is a window open, how long does it stay open,
# when does it next open, and does an op's hard budget fit what is left. Op
# execution inside a window: a durable lease first, then enter, verify, the
# `launching` journal entry, the op, its verify, and an exit that always runs.
# Reconciliation: find a lease that outlived its window and exit it, but only
# when no mutation can have started.
#
# The journal is an append-only chain of commits on
# refs/cf-prod/journal/<request_id>, each holding the full entry list. An
# `uncertain` or `launching` journal is never exited or retried automatically:
# the environment stays in maintenance and a human decides. Commands run
# through an injected executor, as an argv with no shell, so tests never reach
# a real system.
#
# `maintenance.verify` exits 0 while maintenance is ON and non-zero once it is
# off, so the same command confirms both the enter and the exit.
module ChangeMaintenance
  class Error < StandardError; end

  # An op that waits for a window waits at most this long; a later window means
  # a later dispatch.
  MAX_WAIT_S = 5 * 3600
  SEARCH_DAYS = 400
  RECONCILER_MAX_AGE_S = 30 * 60
  JOURNAL_PREFIX = 'refs/cf-prod/journal'
  PAYLOAD = ChangeProdStore::PAYLOAD
  ZERO = ChangeProdStore::ZERO
  FIELD_RANGES = { minute: 0..59, hour: 0..23, dom: 1..31, month: 1..12, dow: 0..7 }.freeze

  Result = Struct.new(:ok, :state, :reason, :page, keyword_init: true) do
    def ok? = ok
  end

  # --- windows -----------------------------------------------------------------

  # A parsed five-field cron expression.
  Cron = Struct.new(:minutes, :hours, :doms, :months, :dows, :dom_star, :dow_star) do
    def day?(date)
      return false unless months.include?(date.month)

      dom = doms.include?(date.day)
      dow = dows.include?(date.wday)
      return dom && dow if dom_star || dow_star

      dom || dow # both restricted: cron matches either
    end
  end

  module_function

  def parse_cron(text)
    fields = text.to_s.split
    raise Error, "cron #{text.inspect} must have five fields" unless fields.size == 5

    minute, hour, dom, month, dow = fields.zip(FIELD_RANGES.values).map { |field, range| expand(field, range) }
    dows = dow.map { |value| value % 7 }.to_set
    Cron.new(minute, hour, dom, month, dows, fields[2].start_with?('*'), fields[4].start_with?('*'))
  end

  def expand(field, range)
    field.split(',').flat_map do |part|
      base, step = part.split('/', 2)
      step = step ? Integer(step, 10) : 1
      raise Error, "cron step in #{field.inspect} must be positive" unless step.positive?

      from, to = span(base, range)
      (from..to).step(step).to_a
    end.to_set.tap { |set| raise Error, "cron field #{field.inspect} is out of range" unless set.all? { |value| range.cover?(value) } }
  rescue ArgumentError
    raise Error, "cron field #{field.inspect} is not numeric"
  end

  def span(base, range)
    return [ range.begin, range.end ] if base == '*'

    from, to = base.split('-', 2).map { |value| Integer(value, 10) }
    [ from, to || from ]
  end

  # Runs the block with TZ set to the window's zone, restoring it after.
  def with_tz(tz)
    previous = ENV.fetch('TZ', nil)
    ENV['TZ'] = tz
    yield
  ensure
    previous.nil? ? ENV.delete('TZ') : ENV['TZ'] = previous
  end

  # Every start of `cron` on local dates from..to, ascending, as Times.
  def starts_on(cron, from_date, to_date)
    (from_date..to_date).flat_map do |date|
      next [] unless cron.day?(date)

      cron.hours.sort.flat_map { |hour| cron.minutes.sort.map { |minute| Time.local(date.year, date.month, date.day, hour, minute) } }
    end
  end

  # The window at `now`: { open:, starts_at:, ends_at:, remaining_s: } when open,
  # { open: false, next_start: } (nil when none within a year) otherwise.
  def window_state(window, now)
    duration = window.fetch('duration_minutes').to_i * 60
    with_tz(window.fetch('tz')) do
      cron = parse_cron(window.fetch('cron'))
      local = Time.at(now.to_i)
      recent = starts_on(cron, Time.at(now.to_i - duration).to_date, local.to_date).select { |start| start <= local && start + duration > local }
      if recent.any?
        start = recent.max
        next { open: true, starts_at: start, ends_at: start + duration, remaining_s: (start + duration - local).to_i }
      end
      upcoming = starts_on(cron, local.to_date, local.to_date + SEARCH_DAYS).find { |start| start > local }
      { open: false, next_start: upcoming }
    end
  rescue KeyError => e
    raise Error, "window is missing #{e.key}"
  end

  # --- budget ---------------------------------------------------------------------

  def op_definition(config, op_name)
    op = config.dig('change_config', 'operations', op_name)
    raise Error, "no op named #{op_name}" unless op.is_a?(Hash)

    op
  end

  def maintenance_block(config)
    block = config.dig('change_config', 'maintenance')
    block.is_a?(Hash) ? block : {}
  end

  def timeout_of(command)
    command.is_a?(Hash) ? command['timeout_s'].to_i : 0
  end

  # enter + verify + op timeout + op verify + exit + verify. Maintenance verify
  # runs twice (after enter, and again to confirm the exit), so it counts twice.
  # `estimate` is informational and never enters the sum. An op with no enter
  # command runs none of the maintenance commands.
  def budget_s(config, op_name)
    op = op_definition(config, op_name)
    raise Error, "op #{op_name} has no timeout_s" unless op['timeout_s'].to_i.positive?

    block = maintenance_block(config)
    around = block['enter'] ? %w[enter verify exit verify].sum { |step| timeout_of(block[step]) } : 0
    around + op['timeout_s'].to_i + timeout_of(op['verify'])
  end

  # What to do now for an op. :online_safe (no window, reason recorded), :run
  # (the window is open and holds the budget), :wait (wait_s until it opens),
  # :refuse (the window cannot ever or no longer hold the budget).
  def plan(config, op_name, now)
    op = op_definition(config, op_name)
    return { action: :online_safe, reason: op.dig('online_safe', 'reason') } if op['online_safe']

    window = config.dig('change_config', 'maintenance', 'windows', op['maintenance'].to_s)
    return { action: :refuse, reason: "op #{op_name} names no declared window" } unless window.is_a?(Hash)

    budget = budget_s(config, op_name)
    total = window['duration_minutes'].to_i * 60
    return { action: :refuse, reason: "budget #{budget}s exceeds the whole #{total}s window #{op['maintenance']}", budget_s: budget } if budget > total

    state = window_state(window, now)
    return plan_open(state, budget, op) if state[:open]
    return { action: :refuse, reason: "window #{op['maintenance']} never opens" } unless state[:next_start]

    wait = (state[:next_start] - Time.at(now.to_i)).ceil
    return { action: :refuse, reason: "window #{op['maintenance']} opens in #{wait}s, past the #{MAX_WAIT_S}s wait limit; dispatch later", budget_s: budget } if wait > MAX_WAIT_S

    { action: :wait, wait_s: wait, budget_s: budget }
  end

  def plan_open(state, budget, op)
    if state[:remaining_s] < budget
      return { action: :refuse, reason: "#{state[:remaining_s]}s left in window #{op['maintenance']} cannot hold the #{budget}s budget", budget_s: budget }
    end

    { action: :run, budget_s: budget, ends_at: state[:ends_at], remaining_s: state[:remaining_s] }
  end

  # Substitutes {name} placeholders from declared, pattern-checked params. No
  # shell sees the result.
  def render_argv(argv, definitions, params)
    argv.map do |arg|
      arg.gsub(/\{([^{}]*)\}/) do
        name = Regexp.last_match(1)
        definition = definitions.is_a?(Hash) ? definitions[name] : nil
        raise Error, "placeholder {#{name}} is not a declared param" unless definition.is_a?(Hash)

        value = params[name].to_s
        raise Error, "param #{name} does not match its pattern" unless value.match?(Regexp.new(definition.fetch('pattern', '\A\z')))

        value
      end
    end
  end

  # A maintenance verify run read as :on (exit 0), :off (it ran and exited
  # non-zero) or :unknown (it timed out or never started). Only :off confirms
  # an exit: a timeout says nothing about the state.
  def maintenance_state(outcome)
    return :on if outcome.ok?
    return :unknown if outcome.timed_out || outcome.spawn_failed

    :off
  end

  # --- journal ----------------------------------------------------------------------

  # Append-only journal on refs/cf-prod/journal/<request_id>. Each commit's
  # payload is the whole entry list; the parent chain keeps the history. An
  # append is a compare-and-swap on the old tip and a non-forced push, so two
  # writers cannot both extend the same tip.
  class Journal
    def initialize(root, remote: 'origin', push: true)
      @root = root
      @remote = remote
      @push = push
    end

    def ref(request_id)
      raise Error, 'request_id is not a uuid' unless request_id.to_s.match?(ChangeProdEnvelope::UUID)

      "#{JOURNAL_PREFIX}/#{request_id}"
    end

    def fetch
      _out, err, status = git('fetch', '--quiet', @remote, "+#{JOURNAL_PREFIX}/*:#{JOURNAL_PREFIX}/*")
      raise Error, "fetching the journal failed: #{err.strip}" unless status.success?
    end

    def ids
      out, _err, status = git('for-each-ref', '--format=%(refname)', "#{JOURNAL_PREFIX}/")
      return [] unless status.success?

      out.lines.map { |line| line.strip.delete_prefix("#{JOURNAL_PREFIX}/") }.reject(&:empty?)
    end

    def entries(request_id)
      out, _err, status = git('show', "#{ref(request_id)}:#{PAYLOAD}")
      return [] unless status.success?

      JSON.parse(out)
    rescue JSON::ParserError
      raise Error, "#{ref(request_id)} does not hold valid JSON"
    end

    def append(request_id, entry)
      name = ref(request_id)
      tip = rev(name)
      current = tip ? entries(request_id) : []
      payload = JSON.generate(current + [ entry ])
      commit = write_commit(payload, tip)
      _out, err, status = git('update-ref', name, commit, tip || ZERO)
      raise Error, "#{name} moved while appending: #{err.strip}" unless status.success?

      publish(name, tip)
      entry
    end

    private

    def publish(name, tip)
      return unless @push

      _out, err, status = git('push', @remote, "#{name}:#{name}")
      return if status.success?

      tip ? git('update-ref', name, tip) : git('update-ref', '-d', name)
      raise Error, "#{name} could not be pushed: #{err.lines.last.to_s.strip}"
    end

    def rev(name)
      out, _err, status = git('rev-parse', '--verify', '--quiet', name)
      status.success? ? out.strip : nil
    end

    def write_commit(json, parent)
      blob = capture('hash-object', '-w', '--stdin', stdin: json)
      tree = capture('mktree', stdin: "100644 blob #{blob}\t#{PAYLOAD}\n")
      args = [ '-c', 'commit.gpgsign=false', '-c', 'user.name=cf-prod', '-c', 'user.email=cf-prod@users.noreply.github.com', 'commit-tree', tree, '-m', 'cf-prod journal' ]
      args.push('-p', parent) if parent
      capture(*args)
    end

    def capture(*args, stdin: nil)
      out, err, status = git(*args, stdin: stdin)
      raise Error, "git #{args.first} failed: #{err.strip}" unless status.success?

      out.strip
    end

    def git(*args, stdin: nil)
      Open3.capture3('git', '-C', @root, *args, stdin_data: stdin.to_s)
    end
  end

  # --- execution -----------------------------------------------------------------

  # Runs one approved op. `before` is called once the window is open and before
  # maintenance is entered; it is where the caller rechecks approval and takes
  # the fresh snapshot, and must return an object answering ok? and reason.
  # `sleeper` and `clock` are injected so tests neither wait nor read the time.
  class Runner
    def initialize(config:, journal:, executor:, request_id:, environment:, run_id:, clock: -> { Time.now.utc }, sleeper: ->(seconds) { sleep(seconds) }, repo: nil)
      @config = config
      @journal = journal
      @executor = executor
      @request_id = request_id
      @environment = environment
      @run_id = run_id
      @clock = clock
      @sleeper = sleeper
      @repo = repo
    end

    def execute(op_name, params, before: nil)
      refusal = relaunch_refusal
      return refusal if refusal

      op = ChangeMaintenance.op_definition(@config, op_name)
      # Rendered before any lease or enter: a bad param must not leave
      # maintenance on.
      commands = render(op, params)
      decision = await_window(op_name)
      return refuse(decision[:reason]) if decision[:action] == :refuse

      checked = before&.call
      return refuse("pre-mutation check failed: #{checked.reason}") if checked && !checked.ok?

      decision = ChangeMaintenance.plan(@config, op_name, @clock.call)
      return refuse(decision[:reason]) if decision[:action] == :refuse || decision[:action] == :wait

      if decision[:action] == :online_safe
        record('online_safe', reason: decision[:reason])
        return mutate(op, commands)
      end

      windowed(op, commands, decision)
    rescue ChangeMaintenance::Error => e
      refuse(e.message)
    end

    private

    # Never retry a non-idempotent op: a journal that reached launching stays
    # for a human.
    def relaunch_refusal
      states = @journal.entries(@request_id).map { |entry| entry['state'] }
      return nil unless states.include?('launching')

      Result.new(ok: false, state: 'uncertain', reason: 'this request already reached launching; reconcile it or request again', page: true)
    end

    def await_window(op_name)
      decision = ChangeMaintenance.plan(@config, op_name, @clock.call)
      return decision unless decision[:action] == :wait

      record('waiting', wait_s: decision[:wait_s])
      @sleeper.call(decision[:wait_s])
      ChangeMaintenance.plan(@config, op_name, @clock.call)
    end

    def windowed(op, commands, decision)
      block = ChangeMaintenance.maintenance_block(@config)
      return mutate(op, commands) unless block['enter']

      # The lease is durable before enter runs, so a runner lost inside enter
      # still leaves something the reconciler can find.
      record('maintenance_entered', expires_at: decision[:ends_at].utc.iso8601)
      result = enter(block) || mutate(op, commands)
      leave(block, result)
    end

    def enter(block)
      return refuse('maintenance enter failed') unless command(block['enter'])

      refuse('maintenance did not verify as on after enter') unless command(block['verify'])
    end

    def render(op, params)
      argv = ChangeMaintenance.render_argv(op.fetch('argv'), op['params'], params)
      verify = op['verify'] && ChangeMaintenance.render_argv(op['verify'].fetch('argv'), op['params'], params)
      [ argv, verify ]
    end

    # A journal write that fails after launching leaves the outcome unknown, so
    # it pages as uncertain and still lets the caller run exit.
    def mutate(op, commands)
      launch(op, commands)
    rescue ChangeMaintenance::Error => e
      Result.new(ok: false, state: 'uncertain', reason: "journal write failed: #{e.message}", page: true)
    end

    def launch(op, commands)
      argv, verify = commands
      record('launching')
      outcome = @executor.call(argv, timeout: op.fetch('timeout_s'), chdir: @repo)
      return uncertain(outcome.timed_out ? 'op timed out' : 'op failed') unless outcome.ok?
      return uncertain('op verify failed') if verify && !@executor.call(verify, timeout: op['verify']['timeout_s'], chdir: @repo).ok?

      record('observed_complete')
      Result.new(ok: true, state: 'observed_complete', page: false)
    end

    # Exit always runs, success or failure, and its result is confirmed by
    # verify reporting maintenance off. A failed exit pages and keeps the lease.
    def leave(block, result)
      return record_exit(result) if command(block['exit']) && state_of(block['verify']) == :off

      record_quietly('exit_failed')
      reason = [ result.reason, 'maintenance exit was not confirmed' ].compact.join('; ')
      Result.new(ok: false, state: result.ok? ? 'exit_failed' : result.state, reason: reason, page: true)
    end

    def record_exit(result)
      record('maintenance_exited', by: 'runner')
      result
    rescue ChangeMaintenance::Error => e
      Result.new(ok: false, state: result.ok? ? 'exit_failed' : result.state, reason: "maintenance exited but the journal write failed: #{e.message}", page: true)
    end

    def state_of(spec)
      return :off unless spec.is_a?(Hash)

      ChangeMaintenance.maintenance_state(@executor.call(spec.fetch('argv'), timeout: spec['timeout_s'].to_i, chdir: @repo))
    end

    def command(spec)
      return true unless spec.is_a?(Hash)

      @executor.call(spec.fetch('argv'), timeout: spec['timeout_s'].to_i, chdir: @repo).ok?
    end

    def uncertain(reason)
      record('uncertain', reason: reason)
      Result.new(ok: false, state: 'uncertain', reason: reason, page: true)
    end

    def refuse(reason)
      record('refused', reason: reason)
      Result.new(ok: false, state: 'refused', reason: reason, page: false)
    rescue ChangeMaintenance::Error => e
      Result.new(ok: false, state: 'refused', reason: "#{reason}; the journal write failed: #{e.message}", page: false)
    end

    def record_quietly(state)
      record(state)
    rescue ChangeMaintenance::Error
      nil
    end

    def record(state, **extra)
      @journal.append(@request_id, { 'state' => state, 'at' => @clock.call.utc.iso8601, 'run_id' => @run_id.to_s, 'environment' => @environment }.merge(extra.transform_keys(&:to_s)))
    end
  end

  # --- reconciliation --------------------------------------------------------------

  Action = Struct.new(:request_id, :kind, :reason, keyword_init: true)

  # The held lease in a journal, or nil: maintenance_entered with no later
  # maintenance_exited.
  def lease_of(entries)
    index = entries.rindex { |entry| entry['state'] == 'maintenance_entered' }
    return nil unless index
    return nil if entries[index + 1..].any? { |entry| entry['state'] == 'maintenance_exited' }

    entries[index]
  end

  # :skip, :exit or :page for one journal. A lease still inside its window is
  # left alone. Past it, exit only when nothing could have mutated: no
  # `launching`, or an observed-complete or refused result after it. A journal
  # that reached `launching` without a safe result, or is `uncertain`, pages.
  def classify(entries, now)
    lease = lease_of(entries)
    return [ :skip, 'no lease held' ] unless lease
    return [ :skip, 'lease still inside its window' ] if Time.parse(lease['expires_at']) > now

    states = entries.map { |entry| entry['state'] }
    return [ :page, 'uncertain op' ] if states.include?('uncertain')
    return [ :exit, 'no mutation started' ] unless states.include?('launching')
    return [ :exit, 'op observed complete' ] if states.include?('observed_complete')

    [ :page, 'runner lost after launching' ]
  end

  # Walks every journal. Exits what is safe, reports what must page. Returns
  # the actions taken; callers fail the workflow when any is :page.
  def reconcile(config:, journal:, executor:, now: Time.now.utc, run_id: 'reconciler', repo: nil)
    Reconciler.new(block: maintenance_block(config), journal: journal, executor: executor, now: now, run_id: run_id, repo: repo).call
  end

  class Reconciler
    def initialize(block:, journal:, executor:, now:, run_id:, repo:)
      @block = block
      @journal = journal
      @executor = executor
      @now = now
      @run_id = run_id
      @repo = repo
    end

    def call
      judged = @journal.ids.map do |id|
        entries = @journal.entries(id)
        [ id, entries, *ChangeMaintenance.classify(entries, @now) ]
      end
      judged.filter_map do |id, entries, kind, reason|
        next if kind == :skip # a live lease is a run in progress, not an action

        next Action.new(request_id: id, kind: :page, reason: reason) if kind == :page

        holder = other_holder(judged, id, entries)
        next Action.new(request_id: id, kind: :hold, reason: "maintenance stays on: #{holder} holds a lease in the same environment") if holder

        reason = exit_lease(id, entries)
        Action.new(request_id: id, kind: reason == NOT_CONFIRMED ? :page : kind, reason: reason)
      end
    end

    private

    # Another request in the same environment whose lease is live or paged:
    # exiting maintenance now would disable it underneath that operation.
    def other_holder(judged, id, entries)
      environment = ChangeMaintenance.lease_of(entries)['environment']
      other = judged.find do |other_id, other_entries, kind, _|
        lease = ChangeMaintenance.lease_of(other_entries)
        other_id != id && kind != :exit && lease && lease['environment'] == environment
      end
      other&.first
    end

    NOT_CONFIRMED = 'exit not confirmed'

    # Exit only a lease that is still on; verify must read off afterwards. With
    # no exit command there is nothing to run, so the lease is only recorded.
    def exit_lease(id, entries)
      return NOT_CONFIRMED unless !@block['exit'] || exited?

      @journal.append(id, { 'state' => 'maintenance_exited', 'at' => @now.utc.iso8601, 'run_id' => @run_id.to_s,
                            'environment' => ChangeMaintenance.lease_of(entries)['environment'], 'by' => 'reconciler' })
      'exited by the reconciler'
    end

    # True only when verify reads off, before the exit (already off) or after
    # it. A verify that times out is unknown, never off: the lease stays and
    # the action pages.
    def exited?
      return run(@block['exit']).ok? unless @block['verify']

      case state
      when :off then true
      when :unknown then false
      else run(@block['exit']).ok? && state == :off
      end
    end

    def state = ChangeMaintenance.maintenance_state(run(@block['verify']))

    def run(command)
      @executor.call(command.fetch('argv'), timeout: command['timeout_s'].to_i, chdir: @repo)
    end
  end

  # Doctor input: true when the reconciler has not succeeded within 30 minutes.
  def reconciler_stale?(last_success, now: Time.now.utc)
    last_success.nil? || now - last_success > RECONCILER_MAX_AGE_S
  end

  # --- CLI ---------------------------------------------------------------------------

  def run(argv, stdout: $stdout, stderr: $stderr, executor: ChangeBackup::Executor.new, now: Time.now.utc)
    verb = argv.shift
    opts = parse(argv)
    config = ChangeProdEnvelope.load_config(opts.fetch(:config))
    case verb
    when 'plan' then cli_plan(config, opts, stdout, stderr, now)
    when 'reconcile' then cli_reconcile(config, opts, stdout, stderr, executor, now)
    else usage(stderr)
    end
  rescue Error, ChangeProdEnvelope::Invalid, OptionParser::ParseError, KeyError, SystemCallError => e
    stderr.puts "[cf-maintenance] refused: #{e.message}"
    1
  end

  def parse(argv)
    opts = { repo: '.', remote: 'origin' }
    OptionParser.new do |o|
      o.on('--config PATH') { |v| opts[:config] = v }
      o.on('--op NAME') { |v| opts[:op] = v }
      o.on('--repo PATH') { |v| opts[:repo] = v }
      o.on('--remote NAME') { |v| opts[:remote] = v }
    end.parse!(argv)
    opts
  end

  def cli_plan(config, opts, stdout, stderr, now)
    decision = plan(config, opts.fetch(:op), now)
    stdout.puts "[cf-maintenance] #{decision.reject { |key, _| key == :ends_at }.map { |key, value| "#{key}=#{value}" }.join(' ')}"
    decision[:action] == :refuse ? (stderr.puts("[cf-maintenance] refused: #{decision[:reason]}") || 1) : 0
  end

  def cli_reconcile(config, opts, stdout, stderr, executor, now)
    journal = Journal.new(opts[:repo], remote: opts[:remote])
    journal.fetch
    actions = reconcile(config: config, journal: journal, executor: executor, now: now, run_id: ENV.fetch('GITHUB_RUN_ID', 'reconciler'), repo: opts[:repo])
    actions.each { |action| stdout.puts "[cf-maintenance] #{action.kind} #{action.request_id}: #{action.reason}" }
    stdout.puts '[cf-maintenance] nothing to reconcile' if actions.empty?
    pages = actions.select { |action| action.kind == :page }
    pages.each { |action| stderr.puts "::error::cf-prod #{action.request_id} needs a human: #{action.reason}" }
    pages.empty? ? 0 : 1
  end

  def usage(stderr)
    stderr.puts 'usage: change_maintenance.rb plan|reconcile --config PATH [--op NAME] [--repo PATH]'
    2
  end
end

exit(ChangeMaintenance.run(ARGV)) if __FILE__ == $PROGRAM_NAME
