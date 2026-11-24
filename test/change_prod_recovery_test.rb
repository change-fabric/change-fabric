# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "git_fixture"
require_relative "../scripts/change_prod_recovery"

# The recovery precondition runs through the real ChangeBackup code; only the
# provider's resource calls are faked (fixture kind or a scripted executor).
class ChangeProdRecoveryTest < Minitest::Test
  Recovery = ChangeProdRecovery
  NOW = Time.utc(2026, 11, 24, 12, 0, 0)
  ID = "11111111-2222-4333-8444-555555555555"

  class Executor
    def initialize(answers) = @answers = answers

    def call(argv, **)
      line = argv.join(" ")
      key = @answers.keys.find { |matcher| line.include?(matcher) }
      answer = key ? @answers[key] : { out: "" }
      ChangeBackup::Outcome.new(ok: answer.fetch(:ok, true), stdout: answer[:out].to_s, stderr: "", timed_out: false)
    end
  end

  def rds_def
    { "kind" => "rds_snapshot", "provider" => "aws", "target" => "db-1", "verify" => { "argv" => [ "verify" ], "timeout_s" => 5 },
      "pitr" => { "required_hours" => 72 } }
  end

  def config(kind: "fixture", op_class: "destructive_data", backup: "main_db")
    backup_def = rds_def.merge("kind" => kind, "restore_probe" => { "argv" => [ "restore_probe" ], "timeout_s" => 5, "max_age_days" => 7 })
    if %w[pg_dump_s3 command].include?(kind)
      backup_def["snapshot"] = { "argv" => [ "dump" ], "timeout_s" => 5 }
      backup_def["pitr_source"] = "pitr_db"
    end
    operation = { "class" => op_class, "runner" => "prod" }
    operation["backup"] = backup if backup
    { "change_config" => { "backups" => { "main_db" => backup_def, "pitr_db" => rds_def }, "operations" => { "purge" => operation } } }
  end

  def envelope = { "op" => "purge", "environment" => "production", "request_id" => ID }

  def sql(text) = ChangeProdSql.analyze(text)

  def fixture_probe(cfg, **fixture)
    ChangeBackup.probe(cfg, "main_db", environment: "production", clock: -> { NOW }, fixture: fixture)
  end

  def precondition(cfg, statements, probe:, **opts)
    Recovery.precondition(config: cfg, envelope: envelope, statements: statements, probe_evidence: probe, clock: -> { NOW }, **opts)
  end

  def test_a_bounded_statement_in_a_routine_op_needs_no_artifact
    cfg = config(op_class: "routine")
    result = precondition(cfg, sql("UPDATE t SET a = 1 WHERE id = 1"), probe: nil, estimated_rows: 3)
    assert_predicate result, :ok?
    refute result.required
    assert_nil result.artifact
  end

  def test_a_destructive_statement_with_a_verified_fixture_artifact_is_allowed
    cfg = config(op_class: "routine")
    result = precondition(cfg, sql("DELETE FROM t"), probe: fixture_probe(cfg), fixture: {})
    assert_predicate result, :ok?, result.reason
    assert result.required
    assert_equal "fixture", result.artifact["kind"]
    assert_match(/\Afixture-/, result.artifact["id"])
  end

  def test_a_destructive_op_class_needs_an_artifact_even_for_a_bounded_statement
    assert Recovery.required?(config, envelope, statements: sql("SELECT 1"))
  end

  def test_an_estimate_over_the_threshold_needs_an_artifact
    cfg = config(op_class: "routine")
    bounded = sql("UPDATE t SET a = 1 WHERE b")
    refute Recovery.required?(cfg, envelope, statements: bounded, estimated_rows: 1000)
    assert Recovery.required?(cfg, envelope, statements: bounded, estimated_rows: 1001)
    assert Recovery.required?(cfg, envelope, statements: bounded, estimated_rows: "?")
  end

  def test_no_artifact_denies_a_destructive_statement
    cfg = config(op_class: "routine")
    result = precondition(cfg, sql("TRUNCATE t"), probe: fixture_probe(cfg), fixture: { snapshot_ok: false })
    refute_predicate result, :ok?
    assert_match(/no verified recovery artifact: fixture snapshot failed/, result.reason)
  end

  def test_an_unverified_snapshot_denies
    cfg = config(op_class: "routine")
    result = precondition(cfg, sql("DROP TABLE t"), probe: fixture_probe(cfg), fixture: { verify_ok: false })
    refute_predicate result, :ok?
    assert_match(/snapshot failed verify/, result.reason)
  end

  def test_a_failed_or_missing_restore_probe_denies
    cfg = config(op_class: "routine")
    refute_predicate precondition(cfg, sql("DROP TABLE t"), probe: fixture_probe(cfg, probe_ok: false), fixture: {}), :ok?
    refute_predicate precondition(cfg, sql("DROP TABLE t"), probe: nil, fixture: {}), :ok?
  end

  def test_an_op_with_no_declared_backup_denies
    cfg = config(op_class: "routine", backup: nil)
    result = precondition(cfg, sql("DROP TABLE t"), probe: nil, fixture: {})
    refute_predicate result, :ok?
    assert_match(/names none/, result.reason)
  end

  def window_answers
    { "describe-db-instances" => { out: JSON.generate("DBInstances" => [ { "BackupRetentionPeriod" => 7 } ]) },
      "describe-db-instance-automated-backups" => { out: JSON.generate("DBInstanceAutomatedBackups" => [
        { "RestoreWindow" => { "EarliestTime" => (NOW - (100 * 3600)).iso8601, "LatestTime" => NOW.iso8601 } }
      ]) } }
  end

  def rds_executor(status: "available")
    Executor.new(window_answers.merge(
                   "create-db-snapshot" => { out: "{}" }, "wait db-snapshot-available" => { out: "" },
                   "describe-db-snapshots" => { out: JSON.generate("DBSnapshots" => [ { "Status" => status, "SnapshotCreateTime" => (NOW - 60).iso8601 } ]) }
                 ))
  end

  def rds_precondition(status)
    cfg = config(kind: "rds_snapshot", op_class: "routine")
    probe = ChangeBackup.probe(cfg, "main_db", environment: "production", clock: -> { NOW }, executor: Executor.new({}))
    precondition(cfg, sql("DROP TABLE t"), probe: probe, executor: rds_executor(status: status))
  end

  def test_an_available_rds_snapshot_is_the_artifact
    result = rds_precondition("available")
    assert_predicate result, :ok?, result.reason
    assert_equal "rds_snapshot", result.artifact["kind"]
    refute_nil result.artifact["id"]
  end

  def test_an_rds_snapshot_that_is_not_available_denies
    result = rds_precondition("creating")
    refute_predicate result, :ok?
    assert_match(/no verified recovery artifact/, result.reason)
  end

  def dump_precondition(line)
    cfg = config(kind: "pg_dump_s3", op_class: "routine")
    executor = Executor.new(window_answers.merge("dump" => { out: line }, "verify" => { out: "ok" }))
    probe = ChangeBackup.probe(cfg, "main_db", environment: "production", clock: -> { NOW }, executor: executor)
    precondition(cfg, sql("TRUNCATE t"), probe: probe, executor: executor)
  end

  def dump_line(**fields) = JSON.generate({ "id" => "dump-1", "created_at" => (NOW - 30).iso8601 }.merge(fields))

  def test_a_dump_with_a_checksum_and_row_counts_is_the_artifact
    ok = dump_precondition(dump_line("sha256" => "a" * 64, "row_counts" => { "users" => 12, "orders" => 0 }))
    assert_predicate ok, :ok?, ok.reason
    assert_equal({ "kind" => "pg_dump_s3", "id" => "dump-1", "sha256" => "a" * 64, "row_counts" => { "users" => 12, "orders" => 0 } }, ok.artifact)
  end

  def test_a_dump_without_a_checksum_or_row_counts_denies
    assert_match(/no recorded sha256/, dump_precondition(dump_line("row_counts" => { "users" => 1 })).reason)
    assert_match(/no recorded sha256/, dump_precondition(dump_line("sha256" => "xyz", "row_counts" => { "users" => 1 })).reason)
    assert_match(/row counts/, dump_precondition(dump_line("sha256" => "a" * 64)).reason)
    assert_match(/row counts/, dump_precondition(dump_line("sha256" => "a" * 64, "row_counts" => {})).reason)
    assert_match(/row counts/, dump_precondition(dump_line("sha256" => "a" * 64, "row_counts" => { "users" => "12" })).reason)
  end

  def test_the_audit_record_carries_statements_counts_and_the_artifact_id
    statements = [ { sql_sha256: "a" * 64, kind: "delete", estimated_rows: 40, actual_rows: 38, extra: "dropped" } ]
    record = Recovery.audit_record(request_id: ID, autopilot_id: "b" * 64, op: "purge", statements: statements,
                                   artifact: { "kind" => "rds_snapshot", "id" => "snap-1" }, result: "ok")
    assert_equal "cf.prod.audit/1", record["protocol"]
    assert_equal [ { "sql_sha256" => "a" * 64, "kind" => "delete", "estimated_rows" => 40, "actual_rows" => 38 } ], record["statements"]
    assert_equal "snap-1", record.dig("artifact", "id")
    assert_equal "b" * 64, record["autopilot_id"]
  end

  def test_the_audit_is_written_once_per_request
    dir = Dir.mktmpdir
    GitFixture.git_init(dir, "-b", "main")
    store = ChangeProdStore.new(dir)
    record = Recovery.audit_record(request_id: ID, autopilot_id: "b" * 64, op: "purge", statements: [], artifact: nil, result: "refused")
    assert_equal "refs/cf-prod/audit/#{ID}", Recovery.write_audit(store, record, push: false)
    assert_equal "refused", store.read("audit", ID)["result"]
    assert_raises(ChangeProdStore::Exists) { Recovery.write_audit(store, record, push: false) }
  ensure
    FileUtils.remove_entry(dir) if dir
  end
end
