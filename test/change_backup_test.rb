# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require "json"
require "tmpdir"
require "stringio"
require_relative "../scripts/change_backup"

# Backup providers and the PITR gate (spec 0.30.0). Nothing here reaches a real
# account: AWS and command calls go through a scripted fake executor.
class ChangeBackupTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/prod/valid.yml", __dir__)
  NOW = Time.utc(2026, 11, 21, 12, 0, 0)

  # Answers each argv from a table keyed by a matcher; records every call.
  class FakeExecutor
    attr_reader :calls

    def initialize(answers = {})
      @answers = answers
      @calls = []
    end

    def call(argv, env: {}, timeout: nil, chdir: nil)
      @calls << { argv: argv, env: env, timeout: timeout, chdir: chdir }
      key = @answers.keys.find { |matcher| argv.join(" ").include?(matcher) }
      answer = key ? @answers[key] : { ok: true, out: "" }
      answer = answer.call if answer.respond_to?(:call)
      ChangeBackup::Outcome.new(ok: answer.fetch(:ok, true), stdout: answer[:out].to_s, stderr: answer[:err].to_s, timed_out: answer[:timed_out] || false)
    end

    def argvs = @calls.map { |call| call[:argv].join(" ") }
  end

  def config = YAML.safe_load_file(FIXTURE)

  def clock(time = NOW) = -> { time }

  def provider(name, env: "production", executor: FakeExecutor.new, cfg: config, **extra)
    ChangeBackup.provider(cfg, name, environment: env, executor: executor, clock: clock, repo: "/repo", **extra)
  end

  def rds_answers(hours: 100, retention: 7, snapshot_status: "available")
  {
    "create-db-snapshot" => { out: "{}" },
    "wait db-snapshot-available" => { out: "" },
    "describe-db-snapshots" => { out: JSON.generate("DBSnapshots" => [ { "Status" => snapshot_status, "SnapshotCreateTime" => (NOW - 120).iso8601 } ]) },
    "describe-db-instances" => { out: JSON.generate("DBInstances" => [ { "BackupRetentionPeriod" => retention } ]) },
    "describe-db-instance-automated-backups" => { out: JSON.generate("DBInstanceAutomatedBackups" => [ { "RestoreWindow" => { "EarliestTime" => (NOW - hours * 3600).iso8601, "LatestTime" => NOW.iso8601 } } ]) }
  }
  end

  def good_set(cfg = config, env: "production", name: "main_db")
    digest = ChangeBackup.digest(cfg, name)
    resource = ChangeBackup.resource(cfg.dig("change_config", "backups", name), env)
    base = { backup: name, environment: env, resource: resource, config_digest: digest }
    {
      "snapshot" => ChangeBackup.evidence(kind: "snapshot", completed_at: NOW, result: "verified", recovery_point: NOW - 60, **base),
      "pitr" => ChangeBackup.evidence(kind: "pitr", completed_at: NOW, result: "measured", extra: { "window_hours" => 100.0 }, **base),
      "probe" => ChangeBackup.evidence(kind: "probe", completed_at: NOW - 86_400, result: "success", **base)
    }
  end

  def check(set, cfg = config, now: NOW) = ChangeBackup.check(cfg, "main_db", environment: "production", evidence: set, now: now)

  # --- providers ---------------------------------------------------------------

  def test_rds_snapshot_creates_waits_and_describes_through_the_aws_cli
    executor = FakeExecutor.new(rds_answers)
    snap = provider("main_db", executor: executor).snapshot
    assert_equal "app-prod", snap["resource"]
    assert_match(/\Acf-backup-app-prod-20261121120000\z/, snap["id"])
    assert_equal NOW - 120, snap["created_at"]
    assert_equal %w[create-db-snapshot wait describe-db-snapshots], executor.argvs.map { |line| line.split[2] }
    assert executor.argvs.all? { |line| line.start_with?("aws rds") && line.end_with?("--output json") }
  end

  def test_snapshot_not_available_is_an_error
    error = assert_raises(ChangeBackup::Error) { provider("main_db", executor: FakeExecutor.new(rds_answers(snapshot_status: "creating"))).snapshot }
    assert_match(/not available/, error.message)
  end

  def test_aws_failure_is_an_error_not_a_silent_pass
    executor = FakeExecutor.new("create-db-snapshot" => { ok: false, err: "AccessDenied" })
    error = assert_raises(ChangeBackup::Error) { provider("main_db", executor: executor).snapshot }
    assert_match(/AccessDenied/, error.message)
  end

  def test_aurora_uses_cluster_calls
    cfg = config
    cfg["change_config"]["backups"]["main_db"]["kind"] = "aurora_snapshot"
    answers = {
      "create-db-cluster-snapshot" => { out: "{}" }, "wait db-cluster-snapshot-available" => {},
      "describe-db-cluster-snapshots" => { out: JSON.generate("DBClusterSnapshots" => [ { "Status" => "available", "SnapshotCreateTime" => NOW.iso8601 } ]) },
      "describe-db-clusters" => { out: JSON.generate("DBClusters" => [ { "BackupRetentionPeriod" => 14, "EarliestRestorableTime" => (NOW - 200 * 3600).iso8601, "LatestRestorableTime" => NOW.iso8601 } ]) }
    }
    executor = FakeExecutor.new(answers)
    prov = provider("main_db", executor: executor, cfg: cfg)
    assert_equal "app-prod", prov.snapshot["resource"]
    assert_in_delta 200.0, prov.pitr_window_hours, 0.01
    assert_includes executor.argvs.join, "--db-cluster-identifier app-prod"
  end

  def test_pitr_window_is_the_time_since_the_earliest_restorable_time
    assert_in_delta 100.0, provider("main_db", executor: FakeExecutor.new(rds_answers(hours: 100))).pitr_window_hours, 0.01
  end

  def window_answers(earliest:, latest:)
    window = { "EarliestTime" => earliest&.iso8601, "LatestTime" => latest&.iso8601 }.compact
    rds_answers.merge("describe-db-instance-automated-backups" => { out: JSON.generate("DBInstanceAutomatedBackups" => [ { "RestoreWindow" => window } ]) })
  end

  def test_a_lagging_latest_restorable_time_does_not_count_as_history
    answers = window_answers(earliest: NOW - 96 * 3600, latest: NOW - 95 * 3600)
    assert_in_delta 1.0, provider("main_db", executor: FakeExecutor.new(answers)).pitr_window_hours, 0.01
  end

  def test_a_missing_or_inverted_restore_window_endpoint_is_unprovable
    [ window_answers(earliest: NOW - 96 * 3600, latest: nil), window_answers(earliest: nil, latest: NOW),
      window_answers(earliest: NOW, latest: NOW - 3600) ].each do |answers|
      assert_raises(ChangeBackup::Unprovable) { provider("main_db", executor: FakeExecutor.new(answers)).pitr_window_hours }
    end
  end

  def test_an_aurora_cluster_window_uses_its_latest_restorable_time
    cfg = config
    cfg["change_config"]["backups"]["main_db"]["kind"] = "aurora_snapshot"
    cluster = { "BackupRetentionPeriod" => 14, "EarliestRestorableTime" => (NOW - 96 * 3600).iso8601, "LatestRestorableTime" => (NOW - 95 * 3600).iso8601 }
    executor = FakeExecutor.new("describe-db-clusters" => { out: JSON.generate("DBClusters" => [ cluster ]) })
    assert_in_delta 1.0, provider("main_db", executor: executor, cfg: cfg).pitr_window_hours, 0.01
    cluster.delete("LatestRestorableTime")
    executor = FakeExecutor.new("describe-db-clusters" => { out: JSON.generate("DBClusters" => [ cluster ]) })
    assert_raises(ChangeBackup::Unprovable) { provider("main_db", executor: executor, cfg: cfg).pitr_window_hours }
  end

  def test_retention_caps_the_pitr_window
    window = provider("main_db", executor: FakeExecutor.new(rds_answers(hours: 400, retention: 2))).pitr_window_hours
    assert_in_delta 48.0, window, 0.01
  end

  def test_retention_zero_cannot_prove_pitr
    error = assert_raises(ChangeBackup::Unprovable) { provider("main_db", executor: FakeExecutor.new(rds_answers(retention: 0))).pitr_window_hours }
    assert_match(/retention 0/, error.message)
  end

  def test_no_restore_window_cannot_prove_pitr
    answers = rds_answers.merge("describe-db-instance-automated-backups" => { out: JSON.generate("DBInstanceAutomatedBackups" => []) })
    assert_raises(ChangeBackup::Unprovable) { provider("main_db", executor: FakeExecutor.new(answers)).pitr_window_hours }
  end

  def test_per_environment_targets_select_the_resource
    assert_equal "app-staging", provider("main_db", env: "staging").resource
    error = assert_raises(ChangeBackup::Error) { provider("main_db", env: "qa").resource }
    assert_match(/no target for environment qa/, error.message)
  end

  def test_verify_runs_the_configured_command_with_the_snapshot_in_its_environment
    executor = FakeExecutor.new(rds_answers)
    ok, = provider("main_db", executor: executor).verify({ "id" => "snap-1" })
    assert ok
    call = executor.calls.last
    assert_equal [ "scripts/verify_snapshot.sh" ], call[:argv]
    assert_equal "snap-1", call[:env]["CF_BACKUP_SNAPSHOT_ID"]
    assert_equal "app-prod", call[:env]["CF_BACKUP_RESOURCE"]
    assert_equal 600, call[:timeout]
    assert_equal "/repo", call[:chdir]
  end

  def test_a_failed_verify_command_is_not_ok
    executor = FakeExecutor.new("verify_snapshot" => { ok: false, err: "checksum mismatch" })
    ok, detail = provider("main_db", executor: executor).verify({ "id" => "s" })
    refute ok
    assert_equal "checksum mismatch", detail
  end

  def test_pg_dump_s3_snapshots_through_its_command_and_borrows_pitr_from_its_source
    line = JSON.generate("id" => "dump-1", "created_at" => (NOW - 30).iso8601)
    executor = FakeExecutor.new(rds_answers.merge("scripts/dump.sh" => { out: "noise\n#{line}\n" }))
    prov = provider("dump_db", executor: executor)
    snap = prov.snapshot
    assert_equal "dump-1", snap["id"]
    assert_equal "app-dump", snap["resource"]
    assert_equal NOW - 30, snap["created_at"]
    assert_in_delta 100.0, prov.pitr_window_hours, 0.01
    assert_includes executor.argvs.join(" "), "describe-db-instances --db-instance-identifier app-prod"
  end

  def test_a_command_snapshot_that_prints_no_json_is_an_error
    executor = FakeExecutor.new("scripts/dump.sh" => { out: "done" })
    assert_raises(ChangeBackup::Error) { provider("dump_db", executor: executor).snapshot }
  end

  def test_a_command_snapshot_without_created_at_is_refused_not_dated_now
    executor = FakeExecutor.new("scripts/dump.sh" => { out: JSON.generate("id" => "dump-1") })
    error = assert_raises(ChangeBackup::Error) { provider("dump_db", executor: executor).snapshot }
    assert_match(/created_at is missing/, error.message)
  end

  def test_a_command_backup_without_a_pitr_source_cannot_prove_pitr
    cfg = config
    cfg["change_config"]["backups"]["dump_db"].delete("pitr_source")
    assert_raises(ChangeBackup::Unprovable) { provider("dump_db", cfg: cfg).pitr_window_hours }
  end

  def test_a_pitr_source_that_cannot_prove_pitr_fails_closed
    cfg = config
    cfg["change_config"]["backups"]["dump_db"]["pitr_source"] = "dump_db"
    error = assert_raises(ChangeBackup::Unprovable) { provider("dump_db", cfg: cfg).pitr_window_hours }
    assert_match(/cannot prove PITR/, error.message)
  end

  def test_restore_probe_runs_the_configured_command
    executor = FakeExecutor.new
    ok, = provider("main_db", executor: executor).restore_probe
    assert ok
    assert_equal [ "scripts/restore_probe.sh" ], executor.calls.last[:argv]
    assert_equal 3600, executor.calls.last[:timeout]
  end

  def test_fixture_provider_reports_its_options
    cfg = config
    cfg["change_config"]["backups"]["main_db"]["kind"] = "fixture"
    prov = provider("main_db", cfg: cfg, fixture: { pitr_hours: 10 })
    assert_in_delta 10.0, prov.pitr_window_hours
    assert_equal "app-prod", prov.snapshot["resource"]
    assert_raises(ChangeBackup::Unprovable) { provider("main_db", cfg: cfg, fixture: { pitr_hours: nil }).pitr_window_hours }
    assert_raises(ChangeBackup::Error) { provider("main_db", cfg: cfg, fixture: { snapshot_ok: false }).snapshot }
  end

  # --- the gate ----------------------------------------------------------------

  def test_good_evidence_passes
    assert check(good_set).ok?
  end

  def test_pitr_below_72_hours_refuses
    set = good_set
    set["pitr"]["window_hours"] = 71.9
    refute check(set).ok?
    assert_match(/PITR window is 71.9 hours; 72 are required/, check(set).reason)
  end

  def test_the_config_cannot_lower_the_pitr_floor
    cfg = config
    cfg["change_config"]["backups"]["main_db"]["pitr"] = { "required_hours" => 1 }
    set = good_set(cfg)
    set["pitr"]["window_hours"] = 10.0
    assert_match(/72 are required/, check(set, cfg).reason)
  end

  def test_a_higher_configured_pitr_requirement_applies
    cfg = config
    cfg["change_config"]["backups"]["main_db"]["pitr"] = { "required_hours" => 120 }
    assert_match(/120 are required/, check(good_set(cfg), cfg).reason)
  end

  def test_unprovable_pitr_refuses
    set = good_set
    set["pitr"]["result"] = "unprovable"
    set["pitr"]["detail"] = "command cannot prove PITR"
    assert_match(/PITR cannot be proven/, check(set).reason)
  end

  def test_a_stale_probe_refuses
    set = good_set
    set["probe"]["completed_at"] = (NOW - (7 * 86_400 + 60)).iso8601
    assert_match(/restore probe is 7.0 days old; at most 7/, check(set).reason)
  end

  def test_a_probe_just_inside_seven_days_passes
    set = good_set
    set["probe"]["completed_at"] = (NOW - (7 * 86_400 - 60)).iso8601
    assert check(set).ok?
  end

  def test_the_config_cannot_lift_the_probe_age_above_seven_days
    cfg = config
    cfg["change_config"]["backups"]["main_db"]["restore_probe"]["max_age_days"] = 30
    set = good_set(cfg)
    set["probe"]["completed_at"] = (NOW - 8 * 86_400).iso8601
    refute check(set, cfg).ok?
  end

  def test_a_shorter_configured_probe_age_applies
    cfg = config
    cfg["change_config"]["backups"]["main_db"]["restore_probe"]["max_age_days"] = 2
    set = good_set(cfg)
    set["probe"]["completed_at"] = (NOW - 3 * 86_400).iso8601
    assert_match(/at most 2 are allowed/, check(set, cfg).reason)
  end

  def test_a_failed_probe_refuses
    set = good_set
    set["probe"]["result"] = "failed"
    set["probe"]["detail"] = "restore timed out"
    assert_match(/restore probe failed: restore timed out/, check(set).reason)
  end

  def test_a_missing_probe_refuses
    set = good_set
    set["probe"] = nil
    assert_match(/no probe evidence/, check(set).reason)
  end

  def test_a_snapshot_that_failed_verify_refuses
    set = good_set
    set["snapshot"]["result"] = "failed"
    set["snapshot"]["detail"] = "checksum mismatch"
    assert_match(/snapshot failed verify: checksum mismatch/, check(set).reason)
  end

  def test_a_snapshot_older_than_fifteen_minutes_refuses
    set = good_set
    set["snapshot"]["recovery_point"] = (NOW - 16 * 60).iso8601
    assert_match(/snapshot is 16 minutes old/, check(set).reason)
  end

  def test_a_future_dated_probe_or_snapshot_refuses
    set = good_set
    set["probe"]["completed_at"] = (NOW + 3600).iso8601
    assert_match(/future/, check(set).reason)
    set = good_set
    set["snapshot"]["recovery_point"] = (NOW + 3600).iso8601
    assert_match(/future/, check(set).reason)
  end

  def test_evidence_for_another_environment_or_resource_refuses
    set = good_set
    set["probe"]["environment"] = "staging"
    assert_match(/environment "staging", not production/, check(set).reason)
    set = good_set
    set["probe"]["resource"] = "app-staging"
    assert_match(/names resource "app-staging", not app-prod/, check(set).reason)
  end

  def test_evidence_for_a_changed_backup_config_refuses
    cfg = config
    set = good_set(cfg)
    cfg["change_config"]["backups"]["main_db"]["verify"]["argv"] = [ "true" ]
    assert_match(/different backup config/, check(set, cfg).reason)
  end

  def test_evidence_with_the_wrong_protocol_or_kind_refuses
    set = good_set
    set["probe"]["protocol"] = "cf.backup.evidence/0"
    assert_match(/is not cf.backup.evidence\/1/, check(set).reason)
    set = good_set
    set["probe"], set["pitr"] = set["pitr"], set["probe"]
    refute check(set).ok?
  end

  def test_a_non_numeric_pitr_window_refuses
    set = good_set
    set["pitr"]["window_hours"] = "999"
    assert_match(/not a number/, check(set).reason)
  end

  # --- gate end to end through the provider ---------------------------------------

  def probe_record(**over)
    good_set["probe"].merge(over)
  end

  def run_gate(executor, probe: probe_record, cfg: config)
    ChangeBackup.gate(cfg, "main_db", environment: "production", probe_evidence: probe, executor: executor, clock: clock, repo: "/repo")
  end

  def test_gate_passes_with_a_fresh_snapshot_enough_pitr_and_a_recent_probe
    result = run_gate(FakeExecutor.new(rds_answers))
    assert result.ok?, result.reason
    assert_equal %w[snapshot pitr probe], result.evidence.keys
    assert_equal "verified", result.evidence["snapshot"]["result"]
  end

  def test_gate_refuses_when_pitr_is_short
    result = run_gate(FakeExecutor.new(rds_answers(hours: 40)))
    refute result.ok?
    assert_match(/PITR window is 40.0 hours/, result.reason)
  end

  def test_gate_refuses_when_the_snapshot_fails_verify
    result = run_gate(FakeExecutor.new(rds_answers.merge("verify_snapshot" => { ok: false, err: "bad" })))
    assert_match(/failed verify: bad/, result.reason)
  end

  def test_gate_refuses_when_the_snapshot_cannot_be_taken
    result = run_gate(FakeExecutor.new(rds_answers.merge("create-db-snapshot" => { ok: false, err: "Throttled" })))
    refute result.ok?
    assert_match(/Throttled/, result.reason)
  end

  def test_gate_refuses_when_pitr_is_unprovable
    result = run_gate(FakeExecutor.new(rds_answers(retention: 0)))
    assert_match(/PITR cannot be proven/, result.reason)
  end

  def test_gate_refuses_without_a_probe
    assert_match(/no probe evidence/, run_gate(FakeExecutor.new(rds_answers), probe: nil).reason)
  end

  def test_probe_records_failure_as_evidence_not_an_exception
    ok = ChangeBackup.probe(config, "main_db", environment: "production", executor: FakeExecutor.new, clock: clock, repo: "/repo")
    assert_equal "success", ok["result"]
    bad = ChangeBackup.probe(config, "main_db", environment: "production", clock: clock, repo: "/repo",
                                                executor: FakeExecutor.new("restore_probe" => { ok: false, timed_out: true }))
    assert_equal "failed", bad["result"]
    assert_equal "timed out", bad["detail"]
    assert_equal ChangeBackup.digest(config, "main_db"), bad["config_digest"]
  end

  def test_evidence_detail_is_truncated
    record = ChangeBackup.evidence(kind: "probe", backup: "b", environment: "e", resource: "r", config_digest: "d", completed_at: NOW, result: "failed", detail: "x" * 2000)
    assert_equal ChangeBackup::DETAIL_LIMIT, record["detail"].length
  end

  # --- the real executor and the CLI ------------------------------------------------

  def test_real_executor_runs_an_argv_without_a_shell_and_kills_on_timeout
    executor = ChangeBackup::Executor.new
    out = executor.call([ "echo", "a;b" ], env: { "X" => "1" }, timeout: 5)
    assert out.ok?
    assert_equal "a;b", out.stdout.strip
    slow = executor.call([ "sleep", "5" ], timeout: 0.2)
    assert slow.timed_out
    refute slow.ok?
    refute executor.call([ "/nonexistent/binary" ], timeout: 1).ok?
  end

  def test_real_executor_never_gives_a_one_element_argv_to_a_shell
    out = ChangeBackup::Executor.new.call([ "printf first; printf second" ], timeout: 5)
    refute out.ok?
    refute_includes out.stdout, "first"
  end

  # A child the command started must not keep the run, or its output pipes,
  # alive past the timeout.
  def test_real_executor_kills_the_whole_process_group_on_timeout
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out = ChangeBackup::Executor.new.call([ "sh", "-c", "sleep 30 & sleep 30" ], timeout: 0.3)
    assert out.timed_out
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
  end

  def with_config(cfg = config)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "CHANGE.yml")
      File.write(path, YAML.dump(cfg))
      yield dir, path
    end
  end

  def fixture_config(**)
    cfg = config
    cfg["change_config"]["backups"]["main_db"]["kind"] = "fixture"
    cfg
  end

  def test_cli_probe_writes_evidence_and_exits_by_result
    with_config(fixture_config) do |dir, path|
      out = StringIO.new
      code = ChangeBackup.run(%w[probe --backup main_db --environment production --out] + [ File.join(dir, "ev"), "--config", path ], stdout: out, stderr: StringIO.new)
      assert_equal 0, code
      record = JSON.parse(File.read(File.join(dir, "ev", "probe-main_db-production.json")))
      assert_equal "success", record["result"]
      assert_equal ChangeBackup.digest(fixture_config, "main_db"), record["config_digest"]
    end
  end

  def test_cli_probe_exits_non_zero_and_still_writes_a_failed_record
    with_config(fixture_config) do |dir, path|
      err = StringIO.new
      code = ChangeBackup.run(%w[probe --backup main_db --environment production --out] + [ File.join(dir, "ev"), "--config", path ], stdout: StringIO.new, stderr: err, fixture: { probe_ok: false })
      assert_equal 1, code
      assert_equal "failed", JSON.parse(File.read(File.join(dir, "ev", "probe-main_db-production.json")))["result"]
      assert_match(/restore probe failed/, err.string)
    end
  end

  def test_cli_gate_refuses_a_missing_probe_file_and_passes_with_one
    cfg = fixture_config
    with_config(cfg) do |dir, path|
      args = %w[gate --backup main_db --environment production --config] + [ path, "--probe-evidence", File.join(dir, "probe.json") ]
      err = StringIO.new
      assert_equal 1, ChangeBackup.run(args.dup, stdout: StringIO.new, stderr: err, clock: clock)
      assert_match(/no probe evidence/, err.string)
      File.write(File.join(dir, "probe.json"), JSON.generate(good_set(cfg)["probe"]))
      out = StringIO.new
      assert_equal 0, ChangeBackup.run(args.dup + [ "--out", File.join(dir, "ev") ], stdout: out, stderr: StringIO.new, clock: clock)
      assert_includes out.string, "PITR and restore probe pass"
      assert_equal %w[pitr probe snapshot], Dir[File.join(dir, "ev", "*.json")].map { |file| File.basename(file).split("-").first }.sort
    end
  end

  def test_cli_pitr_reports_or_refuses
    with_config(fixture_config) do |_dir, path|
      out = StringIO.new
      assert_equal 0, ChangeBackup.run(%w[pitr --backup main_db --environment production --config] + [ path ], stdout: out, stderr: StringIO.new, fixture: { pitr_hours: 80 })
      assert_includes out.string, "80.0 hours"
      err = StringIO.new
      assert_equal 1, ChangeBackup.run(%w[pitr --backup main_db --environment production --config] + [ path ], stdout: StringIO.new, stderr: err, fixture: { pitr_hours: nil })
      assert_match(/refused/, err.string)
    end
  end

  def test_cli_usage_and_bad_arguments
    with_config do |_dir, path|
      assert_equal 2, ChangeBackup.run([ "nope", "--config", path ], stdout: StringIO.new, stderr: StringIO.new)
      assert_equal 1, ChangeBackup.run(%w[probe --backup missing --environment production --out /tmp/x --config] + [ path ], stdout: StringIO.new, stderr: StringIO.new)
    end
  end
end
