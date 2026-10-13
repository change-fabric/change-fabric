#!/usr/bin/env ruby
# frozen_string_literal: true

# The canonical registry of the QA coverage data file (`report-data.js`): its
# line format, the meta record, every field a run record may carry, and the
# per-case record shared by the testcases lane and imported JUnit and TestNG
# results.
#
# Independent of ChangeSchema::VERSION. The data file is not CHANGE.md: it is
# written by the toolkit and read by the coverage page and by any dashboard
# that ingests it, so it carries its own two version numbers. FORMAT_VERSION
# names the file layout (the line prefixes below); RUN_SCHEMA is stamped into
# each run so a reader can skip a run written by a newer toolkit. An additive,
# optional field keeps both; an incompatible change bumps RUN_SCHEMA and adds a
# page adapter.
#
# It gets its own drift test (test/change_coverage_schema_spec_test.rb) against
# SPEC_DOC, as ChangeSuiteSchema does.
module ChangeCoverageSchema
  SPEC_DOC = 'skills/change/reference/qa-coverage-data-spec.md'

  FORMAT_VERSION = 1
  RUN_SCHEMA = 1

  # Line format. A consumer reads line by line: RUN_PREFIX ... RUN_SUFFIX is a
  # run, META_PREFIX ... META_SUFFIX is the meta record, anything else is
  # ignored. HEADER is idempotent so a file loaded twice stays valid.
  HEADER = 'window.CF_QA_COVERAGE = window.CF_QA_COVERAGE || { runs: [] };'
  META_PREFIX = 'window.CF_QA_COVERAGE.meta = '
  META_SUFFIX = ';'
  RUN_PREFIX = 'window.CF_QA_COVERAGE.runs.push('
  RUN_SUFFIX = ');'

  # `change_run` is a deterministic sweep; `import` is a run recorded from CI
  # result files alone.
  SOURCES = %w[change_run import].freeze
  # The selenium lane, when it lands, adds `selenium` here without a schema
  # bump.
  CASE_SOURCES = %w[testcases junit testng].freeze
  CASE_STATUSES = %w[pass fail error skip warn].freeze
  ROUTE_CELL_STATUSES = %w[pass warn fail no_result not_declared lane_off n_a].freeze

  # Dotted paths; `[]` marks a field on each item of a list, the same
  # convention ChangeSchema::FIELDS uses. `<lane>` and `<severity>` stand for a
  # key drawn from ChangeSchema::LANES and a finding severity. A list of
  # per-case records is listed once as `...items[]`; its own keys are
  # CASE_FIELDS.
  FIELDS = [
    'meta.format_version',
    'meta.project',
    'meta.origin',

    'schema',
    'id',
    'sweep_id',
    'recorded_at',
    'source',
    'scope',
    'selection.suites',
    'selection.tags',
    'profile',
    'app',
    'toolkit',
    'repo.root',
    'repo.origin',
    'git.branch',
    'git.sha',
    'git.short_sha',
    'git.subject',
    'git.pr.number',
    'git.pr.url',
    'git.trunk',

    'lanes.configured',
    'lanes.enabled',
    'lanes.ran',
    'lanes.results.<lane>.status',
    'lanes.results.<lane>.findings.pass',
    'lanes.results.<lane>.findings.warn',
    'lanes.results.<lane>.findings.fail',
    'lanes.results.<lane>.by_severity.<severity>',

    'routes.declared_total',
    'routes.declared_exercised',
    'routes.undeclared_exercised',
    'routes.items[].path',
    'routes.items[].declared',
    'routes.items[].declared_by',
    'routes.items[].viewports',
    'routes.items[].lane_status.<lane>',
    'routes.items[].cases_static',
    'routes.items[].cases_reached',

    'cases.defined_total',
    'cases.selected_total',
    'cases.counts.pass',
    'cases.counts.fail',
    'cases.counts.error',
    'cases.counts.skip',
    'cases.counts.warn',
    'cases.counts.flaky',
    'cases.counts.quarantined',
    'cases.counts.ungated',
    'cases.items[]',
    'cases.truncated',

    'suite_inventory[].suite',
    'suite_inventory[].id',
    'suite_inventory[].tags',

    'findings.pass',
    'findings.warn',
    'findings.fail',

    'imports.coverage[].label',
    'imports.coverage[].format',
    'imports.coverage[].file',
    'imports.coverage[].line.covered',
    'imports.coverage[].line.total',
    'imports.coverage[].branch.covered',
    'imports.coverage[].branch.total',
    'imports.coverage[].groups[].name',
    'imports.coverage[].groups[].line.covered',
    'imports.coverage[].groups[].line.total',
    'imports.coverage[].groups[].branch.covered',
    'imports.coverage[].groups[].branch.total',
    'imports.coverage[].groups_truncated',
    'imports.coverage[].timestamp',
    'imports.coverage[].stale',
    'imports.test_results[].label',
    'imports.test_results[].format',
    'imports.test_results[].files',
    'imports.test_results[].counts.pass',
    'imports.test_results[].counts.fail',
    'imports.test_results[].counts.error',
    'imports.test_results[].counts.skip',
    'imports.test_results[].counts.flaky',
    'imports.test_results[].items[]',
    'imports.test_results[].truncated',
    'imports.test_results[].timestamp',
    'imports.test_results[].stale',

    'warnings'
  ].freeze

  # One per-case record, whichever runner produced it. The importers and the
  # testcases lane build these through one helper each so every record carries
  # exactly these keys.
  CASE_FIELDS = [
    'source',
    'suite',
    'id',
    'status',
    'gated',
    'attempts',
    'flaky',
    'duration_ms',
    'tags',
    'message',
    'acceptance_verdict',
    'quarantine.reason',
    'quarantine.until',
    'quarantine.expired',
    'gotos_reached',
    'landed_url'
  ].freeze

  # Caps that keep one run line bounded; counts stay complete past them.
  MAX_CASE_ITEMS = 5000
  MAX_GROUPS = 500
  MESSAGE_MAX = 300
end
