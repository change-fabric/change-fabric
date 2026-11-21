#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'time'
require_relative 'approval_console/canonical'
require_relative 'change_prod_envelope'

# Backups for the bounded prod runner (spec 0.30.0): the providers that take
# and verify a fresh snapshot, report the PITR window and run the restore probe,
# and the gate that refuses an op when the recovery evidence is not good enough.
#
# Every provider call goes through an injected executor (argv in, outcome out),
# so tests and `fixture` backups never reach a real account. The default
# executor shells out to the `aws` CLI and to the config's own commands, always
# as an argv with no shell.
#
# The floors are the ones ChangeProdSchema fixes: PITR of at least 72 hours, a
# restore probe no older than 7 days, and a fresh verified snapshot (no older
# than 15 minutes at mutation start). Evidence records name the source
# resource, the config digest, the recovery point, the completion time and the
# result, and must match the op's environment. Anything unproven refuses.
module ChangeBackup
  PROTOCOL = 'cf.backup.evidence/1'
  MIN_PITR_HOURS = 72
  MAX_PROBE_AGE_DAYS = 7
  MAX_SNAPSHOT_AGE = 15 * 60
  CLOCK_SKEW = 300
  SNAPSHOT_WAIT_S = 3600
  AWS_TIMEOUT_S = 120
  DETAIL_LIMIT = 500
  PITR_KINDS = %w[rds_snapshot aurora_snapshot].freeze

  class Error < StandardError; end
  # PITR cannot be proven for this backup: fail closed.
  class Unprovable < Error; end

  Outcome = Struct.new(:ok, :stdout, :stderr, :timed_out, keyword_init: true) do
    def ok? = ok
  end

  Result = Struct.new(:ok, :reason, :evidence, keyword_init: true) do
    def ok? = ok
  end

  # Runs an argv without a shell, killing it at the timeout.
  class Executor
    # The command runs in its own process group, and the group is killed at the
    # timeout, so a child it started cannot outlive the limit or hold the output
    # pipes open.
    def call(argv, env: {}, timeout: AWS_TIMEOUT_S, chdir: nil)
      options = { pgroup: true }
      options[:chdir] = chdir if chdir
      Open3.popen3(env, *argv, **options) do |stdin, out, err, waiter|
        stdin.close
        readers = [ Thread.new { out.read }, Thread.new { err.read } ]
        finished = waiter.join(timeout)
        kill_group(waiter.pid) unless finished
        waiter.join
        Outcome.new(ok: finished && waiter.value.success?, stdout: readers[0].value.to_s, stderr: readers[1].value.to_s, timed_out: !finished)
      end
    rescue SystemCallError => e
      Outcome.new(ok: false, stdout: '', stderr: e.message, timed_out: false)
    end

    private

    def kill_group(pid)
      Process.kill('KILL', -pid)
    rescue SystemCallError
      nil
    end
  end

  module_function

  def digest(config, name)
    definition = config.dig('change_config', 'backups', name)
    raise Error, "no backup named #{name}" unless definition.is_a?(Hash)

    "sha256:#{Digest::SHA256.hexdigest(ApprovalConsole::Canonical.serialize('backup' => name, 'definition' => definition))}"
  end

  # The one resource this backup covers in `environment`: targets[env] when
  # per-environment, else the single target. A per-environment backup with no
  # entry for the environment has no resource there, so it refuses.
  def resource(definition, environment)
    targets = definition['targets']
    id = targets.is_a?(Hash) ? targets[environment] : definition['target']
    raise Error, "backup has no target for environment #{environment}" unless id.is_a?(String) && !id.empty?

    id
  end

  def evidence(kind:, backup:, environment:, resource:, config_digest:, completed_at:, result:, recovery_point: nil, detail: nil, extra: {})
    record = { 'protocol' => PROTOCOL, 'kind' => kind, 'backup' => backup, 'environment' => environment, 'resource' => resource,
               'config_digest' => config_digest, 'recovery_point' => recovery_point&.utc&.iso8601, 'completed_at' => completed_at.utc.iso8601,
               'result' => result, 'detail' => detail.to_s[0, DETAIL_LIMIT] }
    record.merge(extra)
  end

  # One backup's provider calls: snapshot, verify, pitr_window_hours,
  # restore_probe. Subclasses supply how each kind reaches its resource.
  class Provider
    def initialize(name:, definition:, backups:, environment:, executor:, clock:, repo: nil)
      @name = name
      @definition = definition
      @backups = backups
      @environment = environment
      @executor = executor
      @clock = clock
      @repo = repo
    end

    attr_reader :name, :definition, :environment

    def resource = ChangeBackup.resource(@definition, @environment)

    # {'id', 'resource', 'created_at' (Time)}; raises Error when it cannot.
    def snapshot = raise(NotImplementedError)

    # [ok, detail]
    def verify(_snapshot) = raise(NotImplementedError)

    # Hours of point-in-time recovery available now, or Unprovable.
    def pitr_window_hours = raise(NotImplementedError)

    # [ok, detail]. The probe command restores and tears down what it restored.
    def restore_probe
      probe = @definition['restore_probe']
      raise Error, 'backup has no restore_probe' unless probe.is_a?(Hash)

      outcome = run(probe['argv'], probe['timeout_s'], env_for)
      [ outcome.ok?, summary(outcome) ]
    end

    private

    def now = @clock.call

    def env_for(snapshot = nil)
      env = { 'CF_BACKUP_NAME' => @name, 'CF_BACKUP_ENVIRONMENT' => @environment, 'CF_BACKUP_RESOURCE' => resource }
      env['CF_BACKUP_SNAPSHOT_ID'] = snapshot['id'] if snapshot
      env
    end

    def run(argv, timeout, env = {}, chdir: @repo)
      @executor.call(argv, env: env, timeout: timeout, chdir: chdir)
    end

    def summary(outcome)
      return 'timed out' if outcome.timed_out

      (outcome.ok? ? outcome.stdout : (outcome.stderr.to_s.empty? ? outcome.stdout : outcome.stderr)).to_s.strip
    end

    def verify_command(snapshot)
      verify = @definition['verify']
      outcome = run(verify['argv'], verify['timeout_s'], env_for(snapshot))
      [ outcome.ok?, summary(outcome) ]
    end

    def aws(*args, timeout: AWS_TIMEOUT_S)
      outcome = @executor.call([ 'aws', *args, '--output', 'json' ], env: {}, timeout: timeout, chdir: nil)
      raise Error, "aws #{args.first(2).join(' ')} failed: #{summary(outcome)}" unless outcome.ok?

      outcome.stdout.to_s.strip.empty? ? {} : JSON.parse(outcome.stdout)
    rescue JSON::ParserError
      raise Error, "aws #{args.first(2).join(' ')} returned invalid JSON"
    end

    def parse_time(value, field)
      Time.parse(value.to_s).utc.tap { |time| raise ArgumentError if value.to_s.empty? || time.nil? }
    rescue ArgumentError
      raise Error, "#{field} is missing or not a time"
    end
  end

  # rds_snapshot and aurora_snapshot: the snapshot and PITR window come from the
  # RDS API, and the config's verify command checks the snapshot's contents.
  class AwsSnapshot < Provider
    CALLS = {
      'rds_snapshot' => { create: 'create-db-snapshot', wait: 'db-snapshot-available', describe: 'describe-db-snapshots',
                          id_flag: '--db-instance-identifier', snap_flag: '--db-snapshot-identifier', list: 'DBSnapshots' },
      'aurora_snapshot' => { create: 'create-db-cluster-snapshot', wait: 'db-cluster-snapshot-available', describe: 'describe-db-cluster-snapshots',
                             id_flag: '--db-cluster-identifier', snap_flag: '--db-cluster-snapshot-identifier', list: 'DBClusterSnapshots' }
    }.freeze

    def snapshot
      calls = CALLS.fetch(@definition['kind'])
      id = snapshot_id
      aws('rds', calls[:create], calls[:id_flag], resource, calls[:snap_flag], id)
      aws('rds', 'wait', calls[:wait], calls[:snap_flag], id, timeout: SNAPSHOT_WAIT_S)
      described = aws('rds', calls[:describe], calls[:snap_flag], id).fetch(calls[:list], []).first
      raise Error, "snapshot #{id} was not found after it was created" unless described.is_a?(Hash)
      raise Error, "snapshot #{id} is #{described['Status'].inspect}, not available" unless described['Status'] == 'available'

      { 'id' => id, 'resource' => resource, 'created_at' => parse_time(described['SnapshotCreateTime'], 'SnapshotCreateTime') }
    end

    def verify(snapshot)
      verify_command(snapshot)
    end

    def pitr_window_hours
      hours = @definition['kind'] == 'rds_snapshot' ? instance_window : cluster_window
      raise Unprovable, 'no restorable window reported' unless hours.positive?

      hours
    end

    private

    # Unique per call and valid for RDS: a letter first, then letters, digits
    # and single hyphens.
    def snapshot_id
      slug = resource.gsub(/[^A-Za-z0-9]+/, '-').gsub(/\A-+|-+\z/, '')[0, 40]
      "cf-backup-#{slug}-#{now.utc.strftime('%Y%m%d%H%M%S')}"
    end

    # The retention caps the window a restore could rely on, so a short
    # retention cannot hide behind a currently long history.
    def instance_window
      instance = aws('rds', 'describe-db-instances', '--db-instance-identifier', resource).fetch('DBInstances', []).first
      raise Unprovable, 'instance not found' unless instance.is_a?(Hash)

      retention = instance['BackupRetentionPeriod'].to_i
      raise Unprovable, 'automated backups are off (retention 0)' unless retention.positive?

      backup = aws('rds', 'describe-db-instance-automated-backups', '--db-instance-identifier', resource).fetch('DBInstanceAutomatedBackups', []).first
      window = backup.is_a?(Hash) ? backup['RestoreWindow'] : nil
      raise Unprovable, 'no automated backup restore window' unless window.is_a?(Hash)

      [ span_hours(window['EarliestTime'], window['LatestTime']), retention * 24.0 ].min
    end

    def cluster_window
      cluster = aws('rds', 'describe-db-clusters', '--db-cluster-identifier', resource).fetch('DBClusters', []).first
      raise Unprovable, 'cluster not found' unless cluster.is_a?(Hash)

      retention = cluster['BackupRetentionPeriod'].to_i
      raise Unprovable, 'automated backups are off (retention 0)' unless retention.positive?

      [ span_hours(cluster['EarliestRestorableTime'], cluster['LatestRestorableTime']), retention * 24.0 ].min
    end

    # The recovery history is the span between both ends of the restore window.
    # Measuring from `now` would count time the latest restorable point has
    # not reached, so a missing or inverted endpoint is unprovable.
    def span_hours(earliest, latest)
      raise Unprovable, 'the restore window is missing an endpoint' if earliest.to_s.empty? || latest.to_s.empty?

      first = parse_time(earliest, 'earliest restorable time')
      last = parse_time(latest, 'latest restorable time')
      raise Unprovable, 'the restore window ends before it starts' unless last > first

      (last - first) / 3600.0
    rescue Error => e
      raise Unprovable, e.message
    end
  end

  # pg_dump_s3 and command: the config names the snapshot command, which prints
  # one JSON line {"id": ..., "created_at": ...}. They cannot prove PITR, so the
  # window comes from the backup named by pitr_source, or it is Unprovable.
  class CommandBackup < Provider
    def snapshot
      command = @definition['snapshot']
      raise Error, "#{@definition['kind']} backup needs a snapshot command" unless command.is_a?(Hash)

      outcome = run(command['argv'], command['timeout_s'], env_for)
      raise Error, "snapshot command failed: #{summary(outcome)}" unless outcome.ok?

      line = outcome.stdout.to_s.lines.map(&:strip).reject(&:empty?).last
      data = begin
        JSON.parse(line.to_s)
      rescue JSON::ParserError
        nil
      end
      raise Error, 'snapshot command must print a JSON line with an id' unless data.is_a?(Hash) && data['id'].to_s.match?(/\A[A-Za-z0-9._:\/-]{1,200}\z/)

      created = data['created_at'] ? parse_time(data['created_at'], 'created_at') : now
      { 'id' => data['id'], 'resource' => resource, 'created_at' => created }
    end

    def verify(snapshot)
      verify_command(snapshot)
    end

    def pitr_window_hours
      source = @definition['pitr_source']
      raise Unprovable, "#{@definition['kind']} cannot prove PITR and names no pitr_source" if source.to_s.empty?

      definition = @backups[source.to_s]
      raise Unprovable, "pitr_source #{source} is not a declared backup" unless definition.is_a?(Hash)
      raise Unprovable, "pitr_source #{source} (#{definition['kind']}) cannot prove PITR" unless PITR_KINDS.include?(definition['kind'])

      AwsSnapshot.new(name: source.to_s, definition: definition, backups: @backups, environment: @environment,
                      executor: @executor, clock: @clock, repo: @repo).pitr_window_hours
    end
  end

  # No real resource: results come from the options, for tests and dry runs.
  class Fixture < Provider
    def initialize(fixture: {}, **rest)
      super(**rest)
      @fixture = { pitr_hours: 168.0, snapshot_ok: true, verify_ok: true, probe_ok: true, snapshot_age: 0 }.merge(fixture)
    end

    def snapshot
      raise Error, 'fixture snapshot failed' unless @fixture[:snapshot_ok]

      { 'id' => "fixture-#{now.to_i}", 'resource' => resource, 'created_at' => now - @fixture[:snapshot_age] }
    end

    def verify(_snapshot) = @fixture[:verify_ok] ? [ true, 'fixture verified' ] : [ false, 'fixture verify failed' ]

    def pitr_window_hours
      raise Unprovable, 'fixture reports no PITR' if @fixture[:pitr_hours].nil?

      @fixture[:pitr_hours].to_f
    end

    def restore_probe = @fixture[:probe_ok] ? [ true, 'fixture restored' ] : [ false, 'fixture restore failed' ]
  end

  PROVIDERS = {
    'rds_snapshot' => AwsSnapshot, 'aurora_snapshot' => AwsSnapshot,
    'pg_dump_s3' => CommandBackup, 'command' => CommandBackup, 'fixture' => Fixture
  }.freeze

  # The provider for one backup in one environment.
  def provider(config, name, environment:, executor: Executor.new, clock: -> { Time.now.utc }, repo: nil, fixture: {})
    backups = config.dig('change_config', 'backups')
    definition = backups.is_a?(Hash) ? backups[name] : nil
    raise Error, "no backup named #{name}" unless definition.is_a?(Hash)

    klass = PROVIDERS[definition['kind']] || raise(Error, "unknown backup kind #{definition['kind'].inspect}")
    args = { name: name, definition: definition, backups: backups, environment: environment, executor: executor, clock: clock, repo: repo }
    klass == Fixture ? klass.new(fixture: fixture, **args) : klass.new(**args)
  end

  # Runs the restore probe and returns its evidence record, success or not, so a
  # failed probe is distinguishable from a missing one.
  def probe(config, name, environment:, **options)
    clock = options[:clock] || -> { Time.now.utc }
    provider = provider(config, name, environment: environment, **options)
    ok, detail = begin
      provider.restore_probe
    rescue Error => e
      [ false, e.message ]
    end
    evidence(kind: 'probe', backup: name, environment: environment, resource: provider.resource, config_digest: digest(config, name),
             completed_at: clock.call, result: ok ? 'success' : 'failed', detail: detail)
  end

  # The pre-mutation backup step: a fresh snapshot, its verify, and the PITR
  # window, each recorded as evidence and then judged by `check`. `probe` is
  # the latest restore-probe record (nil when none was found). Returns a Result
  # whose evidence holds the three records.
  def gate(config, name, environment:, probe_evidence:, **options)
    clock = options[:clock] || -> { Time.now.utc }
    provider = provider(config, name, environment: environment, **options)
    snapshot = provider.snapshot
    snap_evidence = snapshot_evidence(provider, config, name, environment, snapshot, clock)
    pitr_evidence = pitr_evidence(provider, config, name, environment, clock)
    set = { 'snapshot' => snap_evidence, 'pitr' => pitr_evidence, 'probe' => probe_evidence }
    judged = check(config, name, environment: environment, evidence: set, now: clock.call)
    Result.new(ok: judged.ok?, reason: judged.reason, evidence: set)
  rescue Error => e
    Result.new(ok: false, reason: e.message, evidence: {})
  end

  def snapshot_evidence(provider, config, name, environment, snapshot, clock)
    ok, detail = provider.verify(snapshot)
    evidence(kind: 'snapshot', backup: name, environment: environment, resource: snapshot['resource'], config_digest: digest(config, name),
             completed_at: clock.call, result: ok ? 'verified' : 'failed', recovery_point: snapshot['created_at'], detail: detail,
             extra: { 'snapshot_id' => snapshot['id'] })
  end

  def pitr_evidence(provider, config, name, environment, clock)
    hours = provider.pitr_window_hours
    evidence(kind: 'pitr', backup: name, environment: environment, resource: provider.resource, config_digest: digest(config, name),
             completed_at: clock.call, result: 'measured', detail: "#{hours.round(1)} hours", extra: { 'window_hours' => hours.to_f })
  rescue Unprovable => e
    evidence(kind: 'pitr', backup: name, environment: environment, resource: provider.resource, config_digest: digest(config, name),
             completed_at: clock.call, result: 'unprovable', detail: e.message, extra: { 'window_hours' => 0.0 })
  end

  # Judges a set of evidence records ({'snapshot','pitr','probe'}) for one
  # backup and environment at `now`. The first failure is the reason.
  def check(config, name, environment:, evidence:, now: Time.now.utc)
    definition = config.dig('change_config', 'backups', name)
    raise Error, "no backup named #{name}" unless definition.is_a?(Hash)

    expected = { backup: name, environment: environment, resource: resource(definition, environment), digest: digest(config, name) }
    snapshot = bound(evidence['snapshot'], 'snapshot', expected)
    pitr = bound(evidence['pitr'], 'pitr', expected)
    probe = bound(evidence['probe'], 'probe', expected)
    check_snapshot(snapshot, now)
    check_pitr(pitr, definition, now)
    check_probe(probe, definition, now)
    Result.new(ok: true, evidence: evidence)
  rescue Error => e
    Result.new(ok: false, reason: e.message)
  end

  def bound(record, kind, expected)
    raise Error, "no #{kind} evidence" unless record.is_a?(Hash)
    raise Error, "#{kind} evidence is not #{PROTOCOL}" unless record['protocol'] == PROTOCOL && record['kind'] == kind
    raise Error, "#{kind} evidence is for backup #{record['backup'].inspect}, not #{expected[:backup]}" unless record['backup'] == expected[:backup]
    raise Error, "#{kind} evidence is for environment #{record['environment'].inspect}, not #{expected[:environment]}" unless record['environment'] == expected[:environment]
    raise Error, "#{kind} evidence names resource #{record['resource'].inspect}, not #{expected[:resource]}" unless record['resource'] == expected[:resource]
    raise Error, "#{kind} evidence was made for a different backup config" unless record['config_digest'] == expected[:digest]

    record
  end

  def time_of(record, field, kind)
    Time.iso8601(record[field].to_s)
  rescue ArgumentError
    raise Error, "#{kind} evidence #{field} is missing or not a time"
  end

  def check_snapshot(record, now)
    raise Error, "snapshot failed verify: #{record['detail']}" unless record['result'] == 'verified'

    point = time_of(record, 'recovery_point', 'snapshot')
    age = now - point
    raise Error, 'snapshot is dated in the future' if -age > CLOCK_SKEW
    raise Error, "snapshot is #{(age / 60).round} minutes old; at most #{MAX_SNAPSHOT_AGE / 60} are allowed at mutation start" if age > MAX_SNAPSHOT_AGE
  end

  def check_pitr(record, definition, now)
    raise Error, "PITR cannot be proven: #{record['detail']}" unless record['result'] == 'measured'

    required = [ pitr_hours(definition), MIN_PITR_HOURS ].max
    hours = record['window_hours']
    raise Error, 'PITR window is not a number' unless hours.is_a?(Numeric)
    raise Error, "PITR window is #{hours.round(1)} hours; #{required} are required" if hours < required

    fresh(record, now, 'PITR')
  end

  def check_probe(record, definition, now)
    raise Error, "restore probe failed: #{record['detail']}" unless record['result'] == 'success'

    limit = [ max_age_days(definition), MAX_PROBE_AGE_DAYS ].min
    age = now - time_of(record, 'completed_at', 'probe')
    raise Error, 'restore probe is dated in the future' if -age > CLOCK_SKEW
    raise Error, "restore probe is #{(age / 86_400).round(1)} days old; at most #{limit} are allowed" if age > limit * 86_400
  end

  def fresh(record, now, label)
    age = now - time_of(record, 'completed_at', label.downcase)
    raise Error, "#{label} measurement is dated in the future" if -age > CLOCK_SKEW
    raise Error, "#{label} measurement is #{(age / 60).round} minutes old" if age > MAX_SNAPSHOT_AGE
  end

  def pitr_hours(definition)
    hours = definition.dig('pitr', 'required_hours')
    hours.is_a?(Integer) ? hours : MIN_PITR_HOURS
  end

  def max_age_days(definition)
    days = definition.dig('restore_probe', 'max_age_days')
    days.is_a?(Integer) && days.positive? ? days : MAX_PROBE_AGE_DAYS
  end

  # --- CLI -----------------------------------------------------------------

  def run(argv, stdout: $stdout, stderr: $stderr, **options)
    verb = argv.shift
    opts = parse(argv)
    config = ChangeProdEnvelope.load_config(opts.fetch(:config))
    case verb
    when 'probe' then cli_probe(config, opts, stdout, stderr, options)
    when 'gate' then cli_gate(config, opts, stdout, stderr, options)
    when 'pitr' then cli_pitr(config, opts, stdout, stderr, options)
    else usage(stderr)
    end
  rescue Error, ChangeProdEnvelope::Invalid, OptionParser::ParseError, KeyError, JSON::ParserError, SystemCallError => e
    stderr.puts "[cf-backup] refused: #{e.message}"
    1
  end

  def parse(argv)
    opts = { repo: '.' }
    OptionParser.new do |o|
      o.on('--config PATH') { |v| opts[:config] = v }
      o.on('--backup NAME') { |v| opts[:backup] = v }
      o.on('--environment NAME') { |v| opts[:environment] = v }
      o.on('--repo PATH') { |v| opts[:repo] = v }
      o.on('--out DIR') { |v| opts[:out] = v }
      o.on('--probe-evidence PATH') { |v| opts[:probe_evidence] = v }
    end.parse!(argv)
    opts
  end

  def cli_probe(config, opts, stdout, stderr, options)
    record = probe(config, opts.fetch(:backup), environment: opts.fetch(:environment), repo: opts[:repo], **options)
    FileUtils.mkdir_p(opts.fetch(:out))
    path = File.join(opts[:out], "probe-#{opts[:backup]}-#{opts[:environment]}.json")
    File.write(path, JSON.pretty_generate(record))
    stdout.puts "[cf-backup] probe #{record['result']}: #{path}"
    return 0 if record['result'] == 'success'

    stderr.puts "[cf-backup] restore probe failed: #{record['detail']}"
    1
  end

  def cli_gate(config, opts, stdout, stderr, options)
    probe_evidence = File.exist?(opts.fetch(:probe_evidence)) ? JSON.parse(File.read(opts[:probe_evidence])) : nil
    result = gate(config, opts.fetch(:backup), environment: opts.fetch(:environment), probe_evidence: probe_evidence, repo: opts[:repo], **options)
    if opts[:out] && !result.evidence.empty?
      FileUtils.mkdir_p(opts[:out])
      result.evidence.each { |kind, record| File.write(File.join(opts[:out], "#{kind}-#{opts[:backup]}-#{opts[:environment]}.json"), JSON.pretty_generate(record)) if record }
    end
    if result.ok?
      stdout.puts '[cf-backup] snapshot verified, PITR and restore probe pass'
      return 0
    end

    stderr.puts "[cf-backup] refused: #{result.reason}"
    1
  end

  def cli_pitr(config, opts, stdout, stderr, options)
    provider = provider(config, opts.fetch(:backup), environment: opts.fetch(:environment), repo: opts[:repo], **options)
    stdout.puts "[cf-backup] PITR window #{provider.pitr_window_hours.round(1)} hours"
    0
  rescue Unprovable => e
    stderr.puts "[cf-backup] refused: #{e.message}"
    1
  end

  def usage(stderr)
    stderr.puts 'usage: change_backup.rb probe|gate|pitr --config PATH --backup NAME --environment NAME [--repo PATH] [--out DIR] [--probe-evidence PATH]'
    2
  end
end

exit(ChangeBackup.run(ARGV)) if __FILE__ == $PROGRAM_NAME
