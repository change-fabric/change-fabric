# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'
require 'rbconfig'
require 'securerandom'
require_relative 'paths'
require_relative 'command'
require_relative 'journal'
require_relative 'limits'
require_relative 'liveness'
require_relative 'grant'

module Triage
  # Runs one model action (C2, C9). The tick never calls Launcher.run: it
  # persists the dispatch and hands this to a detached one-shot job
  # (Launcher::Detach), so a slow action cannot hold the 60 second tick.
  #
  # run: re-check the grant, seed mode admin-bypass, away and the stack lease
  # for the pre-chosen session UUID, spawn one fresh `claude -p --session-id
  # <uuid>` (never --resume, never --bare), register the handshake (pid, start
  # time, boot id, session) before the child mutates anything, wait under a
  # wall-clock timeout, classify the stream, and write the terminal row. A
  # launcher death never frees a lease; only reconcile proves a child dead.
  module Launcher
    WALL_CLOCK = 4 * 3600
    # Findings from the spike: one command per Bash prefix, no compound forms.
    ALLOWED_TOOLS = [ 'Read', 'Edit', 'Write', 'Bash(git:*)', 'Bash(gh:*)', 'Bash(bundle exec:*)', 'Bash(ruby:*)' ].freeze
    PATH = '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'

    def self.new_session = SecureRandom.uuid

    def self.prompt(dispatch_row)
      verb = dispatch_row['verb']
      unit = dispatch_row['unit']
      task = case verb
      when 'start_next' then "Start the next unit #{unit} of its plan or epic and carry it through its phase."
      when 'takeover' then "Take over the abandoned stack for #{unit}: claim the lease and continue its head PR."
      when 'redrive' then "Redrive the head PR of the stack for #{unit}: prepare it again, then hand it off."
      else "Rewatch the head PR of the stack for #{unit} until its checks settle."
      end
      "#{task} Run each shell command on its own line, never chain commands with ; or &&. Work only inside this " \
        'repo at admin-bypass. Stop at carve-outs and release tags and queue them to the inbox. If the autopilot ' \
        'window ends, finish the current reversible step, park the rest to the inbox, and start nothing new.'
    end

    def self.argv(dispatch_row, claude: 'claude')
      [ claude, '-p', prompt(dispatch_row), '--session-id', dispatch_row['session_id'], '--output-format', 'stream-json',
        '--verbose', '--permission-mode', 'acceptEdits', '--allowedTools', ALLOWED_TOOLS.join(',') ]
    end

    def self.env(dispatch_row, root)
      grant = dispatch_row['grant'] || {}
      { 'PATH' => "#{PATH}:#{ENV.fetch('PATH', '')}", 'CF_TRIAGE_HOST' => dispatch_row['host'], 'CF_TRIAGE_ROOT' => root,
        'CF_TRIAGE_ACTION_ID' => dispatch_row['action_id'], 'CF_TRIAGE_GRANT_RECEIPT' => grant['receipt_id'].to_s,
        'CF_TRIAGE_GRANT_EXPIRES' => grant['expires_at'].to_s }
    end

    # Mode and availability for the session id, then the stack lease. Raises
    # Seed::Failed with a reason; the caller parks the dispatch.
    class Seeder
      class Failed < StandardError; end

      def initialize(runner: Command.method(:run), cli: nil)
        @runner = runner
        @cli = cli || [ File.join(Dir.home, '.local/share/change-fabric/bin/cf_cli.rb'),
                        File.expand_path('../cf_cli.rb', __dir__) ].find { |path| File.file?(path) }
      end

      def call(row, pid: Process.pid)
        %w[admin-bypass away].each { |mode| set_mode(row, mode) }
        lease(row['stack'], row['session_id'], pid) if row['stack']
      end

      private

      def set_mode(row, mode)
        raise Failed, 'cf_cli.rb not found' unless @cli

        argv = [ RbConfig.ruby, @cli, 'mode', '--host', 'claude', '--project', row['path'], '--session', row['session_id'], '--mode', mode ]
        result = @runner.call(argv, 30)
        raise Failed, "seeding #{mode} failed: #{result.err.to_s[0, 120]}" unless result.ok
      end

      def lease(stack, session, pid)
        require_relative '../stack_store'
        StackStore.new(stack['repo_id'], stack['slug']).lease(session: session, pid: pid)
      rescue StackStore::Held => e
        raise Failed, "stack lease held: #{e.message}"
      end
    end

    # Runs the dispatch to its terminal row. Returns the terminal type.
    def self.run(action_id, root: Paths.root, journal: Journal.new(root: root), seeder: Seeder.new, grant: Grant.new,
                 spawner: method(:spawn_child), clock: -> { Time.now.utc }, claude: 'claude', wall_clock: WALL_CLOCK,
                 boot_id: -> { Liveness.current_boot_id }, pid_start: Liveness.method(:pid_start), unlease: method(:unlease))
      dispatch = journal.find(action_id)
      return 'unknown' unless dispatch
      return dispatch.terminal['type'] if dispatch.finished?

      row = dispatch.row
      return park(journal, row, 'grant no longer valid', unlease) unless valid_grant?(grant, row, clock.call)

      begin
        seeder.call(row)
      rescue Seeder::Failed => e
        return park(journal, row, e.message, unlease)
      end
      execute(journal, row, root, spawner, claude, wall_clock, clock, boot_id, pid_start, unlease)
    end

    def self.valid_grant?(grant, row, now)
      value = Grant::Value.from(row['grant'])
      grant.still_valid?(value, path: row['path'], now: now)
    rescue StandardError
      false
    end

    def self.execute(journal, row, root, spawner, claude, wall_clock, clock, boot_id, pid_start, unlease)
      FileUtils.mkdir_p(Paths.runs_dir(root))
      out = File.join(Paths.runs_dir(root), "#{row['action_id'].tr(':', '_')}.out")
      child = spawner.call(argv(row, claude: claude), env(row, root), row['path'], out)
      begin
        journal.append('type' => 'handshake', 'action_id' => row['action_id'], 'pid' => child.pid, 'pid_start' => pid_start.call(child.pid),
                       'boot_id' => boot_id.call, 'session_id' => row['session_id'], 'host' => Socket.gethostname, 'fence' => 1)
      rescue Journal::Fenced
        child.kill
        return 'fenced'
      end
      status = child.wait(wall_clock)
      finish(journal, row, root, out, status, clock.call, unlease)
    end

    def self.finish(journal, row, root, out, status, now, unlease)
      text = File.file?(out) ? File.read(out) : ''
      outcome = status == :timeout ? Limits::Outcome.new(klass: 'no_result', detail: 'wall clock timeout') : Limits.classify(text, '', now: now)
      Limits::Store.new(root: root).record(outcome, now: now) if outcome.limit?
      journal.append('type' => 'result', 'action_id' => row['action_id'], 'session_id' => outcome.session_id || row['session_id'],
                     'exit_class' => outcome.klass, 'exit_status' => status.respond_to?(:exitstatus) ? status.exitstatus : nil,
                     'limited_until' => outcome.limited_until&.iso8601, 'detail' => outcome.detail)
      unlease.call(row)
      'result'
    rescue Journal::Fenced
      'fenced'
    end

    def self.park(journal, row, reason, unlease)
      journal.append('type' => 'parked', 'action_id' => row['action_id'], 'reason' => reason)
      unlease.call(row)
      'parked'
    rescue Journal::Fenced
      'fenced'
    end

    # Frees the stack lease for the dispatch's own session only: StackStore
    # refuses a different holder, so a successor's lease is never deleted.
    def self.unlease(row)
      return unless row['stack']

      require_relative '../stack_store'
      StackStore.new(row['stack']['repo_id'], row['stack']['slug']).unlease(session: row['session_id'])
    end

    # A spawned CLI. #wait returns its Process::Status, or :timeout after
    # killing it when the wall-clock limit passes.
    Child = Struct.new(:pid, :waiter) do
      def wait(limit)
        return waiter.value if waiter.join(limit)

        kill
        :timeout
      end

      def kill
        Process.kill('KILL', pid)
      rescue SystemCallError
        nil
      end
    end

    # Spawns the real CLI with stdout and stderr in the run file.
    def self.spawn_child(argv, env, chdir, out)
      pid = Process.spawn(env, *argv, chdir: chdir, in: File::NULL, out: out, err: [ :child, :out ])
      Child.new(pid, Process.detach(pid))
    end

    # The detached one-shot job (C9). The label and unit are cf-triage-<id>.
    module Detach
      def self.label(action_id) = "cf-triage-#{action_id.gsub(/[^A-Za-z0-9._-]/, '-')}"

      def self.command(host:, action_id:, root:, script: File.expand_path('../../triage.rb', __FILE__), ruby: RbConfig.ruby)
        label = label(action_id)
        env = { 'PATH' => PATH, 'CF_TRIAGE_HOST' => host, 'CF_TRIAGE_ROOT' => root, 'HOME' => Dir.home }
        job = [ ruby, script, 'run-action', action_id ]
        if host == 'mini'
          [ 'launchctl', 'submit', '-l', label, '--', '/usr/bin/env', *env.map { |key, value| "#{key}=#{value}" }, *job ]
        else
          [ 'systemd-run', '--user', '--unit', label, *env.map { |key, value| "--setenv=#{key}=#{value}" }, *job ]
        end
      end

      # Submits and returns at once; never waits on the job.
      def self.submit(host:, action_id:, root:, runner: Command.method(:run), **opts)
        result = runner.call(command(host: host, action_id: action_id, root: root, **opts), 20)
        result.ok
      end
    end
  end
end
