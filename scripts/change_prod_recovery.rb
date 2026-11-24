# frozen_string_literal: true

require 'time'
require_relative 'change_backup'
require_relative 'change_prod_classes'
require_relative 'change_prod_sql'
require_relative 'change_prod_store'

# The recovery precondition and the audit record for a prod op that runs under
# an autopilot instead of a per-action phone tap. A per-action approval keeps
# today's rules and never comes here.
#
# A destructive op (class destructive_data, or any destructive statement, or an
# estimate over the op's row threshold) runs only after a recovery artifact is
# taken through ChangeBackup and proven:
#   rds_snapshot, aurora_snapshot   a fresh snapshot in state `available`
#                                   (ChangeBackup's verify), with PITR and a probe
#   pg_dump_s3, command             a dump whose sha256 and per-table row counts
#                                   are recorded in the snapshot evidence
#   fixture                         dry runs only
# With no passing evidence the op is refused. Every run, refused or not, is
# written to refs/cf-prod/audit/<request_id> by `write_audit`.
module ChangeProdRecovery
  AUDIT_PROTOCOL = 'cf.prod.audit/1'
  DUMP_KINDS = %w[pg_dump_s3 command].freeze
  SHA256 = /\A[0-9a-f]{64}\z/

  Result = Struct.new(:ok, :reason, :artifact, :required, keyword_init: true) do
    def ok? = ok
  end

  module_function

  # statements: ChangeProdSql::Statement list; estimated_rows: Integer or nil.
  def required?(config, envelope, statements:, estimated_rows: nil)
    return true if config.dig('change_config', 'operations', envelope['op'], 'class') == 'destructive_data'
    return true if ChangeProdSql.over_threshold?(estimated_rows, ChangeProdSql.threshold_for(config, envelope['op']))

    statements.any?(&:destructive)
  end

  # Takes and judges the artifact for an op that needs one. `probe_evidence` is
  # the latest restore-probe record; provider options (executor, clock, repo,
  # fixture) pass through to ChangeBackup. Returns a Result with the artifact
  # {kind, id, sha256, row_counts} when ok; ok with a nil artifact when none is
  # needed.
  def precondition(config:, envelope:, statements:, probe_evidence:, estimated_rows: nil, **options)
    return Result.new(ok: true, required: false) unless required?(config, envelope, statements: statements, estimated_rows: estimated_rows)

    name = config.dig('change_config', 'operations', envelope['op'], 'backup')
    return refuse('a destructive op under an autopilot needs a declared backup; this op names none') if name.to_s.empty?

    gated = ChangeBackup.gate(config, name, environment: envelope['environment'], probe_evidence: probe_evidence, **options)
    return refuse("no verified recovery artifact: #{gated.reason}") unless gated.ok?

    judge(config, name, gated.evidence['snapshot'])
  rescue ChangeBackup::Error => e
    refuse("no verified recovery artifact: #{e.message}")
  end

  def judge(config, name, snapshot)
    kind = config.dig('change_config', 'backups', name, 'kind')
    artifact = { 'kind' => kind, 'id' => snapshot['snapshot_id'], 'sha256' => snapshot['sha256'], 'row_counts' => snapshot['row_counts'] }
    return refuse('the recovery artifact has no id') if artifact['id'].to_s.empty?

    problem = DUMP_KINDS.include?(kind) ? dump_problem(artifact) : nil
    problem ? refuse(problem) : Result.new(ok: true, artifact: artifact, required: true)
  end

  def dump_problem(artifact)
    return 'the dump has no recorded sha256' unless artifact['sha256'].to_s.match?(SHA256)

    counts = artifact['row_counts']
    ok = counts.is_a?(Hash) && !counts.empty? && counts.all? { |table, rows| table.is_a?(String) && !table.empty? && rows.is_a?(Integer) && rows >= 0 }
    ok ? nil : 'the dump has no recorded per-table row counts'
  end

  def refuse(reason) = Result.new(ok: false, reason: reason, required: true)

  # statements: [{sql_sha256, kind, estimated_rows, actual_rows}].
  def audit_record(request_id:, autopilot_id:, op:, statements:, artifact:, result:)
    { 'protocol' => AUDIT_PROTOCOL, 'request_id' => request_id, 'autopilot_id' => autopilot_id, 'op' => op,
      'statements' => statements.map { |statement| audit_statement(statement) }, 'artifact' => artifact, 'result' => result.to_s }
  end

  def audit_statement(statement)
    row = statement.to_h.transform_keys(&:to_s)
    { 'sql_sha256' => row['sql_sha256'], 'kind' => row['kind'], 'estimated_rows' => row['estimated_rows'], 'actual_rows' => row['actual_rows'] }
  end

  # One record per request; a second write for the same request is refused by
  # the store (conditional create).
  def write_audit(store, record, push: true)
    store.create('audit', record['request_id'], record, push: push)
  end
end
