# QA coverage data file specification

Format version: 1
Run schema: 1

The schema for `report-data.js`, the file every deterministic Change Fabric run
appends one record to and the QA coverage page (`index.html`, beside it) reads.
It is also the ingest contract for anything else that consumes the history, such
as a governance dashboard.

This is not part of the `CHANGE.md` frontmatter spec and never requires a
`ChangeSchema::VERSION` bump. The registry is `ChangeCoverageSchema` in
`scripts/change_coverage_schema.rb`, held to this document by
`test/change_coverage_schema_spec_test.rb`.

## Where the file lives

`~/.claude/cf/coverage/<project>/report-data.js`, where `<project>` is the
slugged project name of the repo's root `CHANGE.md` (never a profile's
override, so every profile of one repo shares one history). Worktrees of the
same repo share it by design. If the directory was created by a repo with a
different origin remote, the store warns and uses `<project>-<first 8 hex of
SHA256(origin)>` instead, so two repos with the same project name never mix.

## Line format and ingest rule

Line 1 is a fixed header, safe to load twice:

```
window.CF_QA_COVERAGE = window.CF_QA_COVERAGE || { runs: [] };
```

Line 2 is the meta record, regenerated on every write:

```
window.CF_QA_COVERAGE.meta = {"format_version":1,"project":"example-co","origin":"git@example.invalid:org\/app.git"};
```

Then exactly one line per run, sorted by `recorded_at` then `id`:

```
window.CF_QA_COVERAGE.runs.push({"schema":1,"id":"20261013T141500Z-1a2b3c4-run",...});
```

Ingest rule for any consumer: read line by line. A line starting with
`window.CF_QA_COVERAGE.runs.push(` and ending with `);` is a run: parse the
text between them as JSON. A line starting with `window.CF_QA_COVERAGE.meta = `
and ending with `;` is the meta record. Ignore every other line. The JSON is
written with `JSON.generate(obj, script_safe: true)`, so `</`, U+2028 and
U+2029 are escaped and no field can end the script early (every `/` is written
as `\/`, which any JSON parser reads back as `/`).

A reader checks each run's `schema` and skips a run whose schema is newer than
it understands.

## Meta

| Field | Type | Description |
| --- | --- | --- |
| `meta.format_version` | integer | The file layout version, 1. |
| `meta.project` | string | The project slug the directory is keyed on. |
| `meta.origin` | string or null | The origin remote of the repo that created the directory, userinfo stripped. |

## Run identity

| Field | Type | Description |
| --- | --- | --- |
| `schema` | integer | The run record schema, 1. |
| `id` | string | Unique run id: `<sweep_id>-run`, `<sweep_id>-run-<app>` in a multi-app sweep, or `<sweep_id>-import-<format>-<label>`. |
| `sweep_id` | string | `<%Y%m%dT%H%M%SZ>-<short sha or nosha>`, shared by every run of one sweep. |
| `recorded_at` | string | ISO 8601 UTC time the run was recorded. |
| `source` | string | `change_run` (a sweep) or `import` (CI result files alone). |
| `scope` | string | The sweep scope (`all`, a lane name) or `import`. |
| `selection.suites` | list of string | Suites a `--suite` selection named; empty when none. |
| `selection.tags` | list of string | Tags a selection named; empty when none. |
| `profile` | string or null | The CHANGE.md profile the run used. |
| `app` | string or null | The registry app key in a multi-app repo. |
| `toolkit` | string | The toolkit version (`git describe` of the toolkit checkout). |
| `repo.root` | string | The repo root, home directory written as `~`. |
| `repo.origin` | string or null | The origin remote URL, userinfo stripped. |
| `git.branch` | string or null | The branch, with CI fallbacks on a detached checkout. |
| `git.sha` | string or null | The full head commit SHA. |
| `git.short_sha` | string or null | The first 7 characters of `git.sha`. |
| `git.subject` | string or null | The head commit subject line. |
| `git.pr.number` | integer | The pull request number (`git.pr` is null when there is none). |
| `git.pr.url` | string or null | The pull request URL. |
| `git.trunk` | boolean | Whether `git.branch` is the configured trunk at write time. |

## Lanes

| Field | Type | Description |
| --- | --- | --- |
| `lanes.configured` | list of string | Every lane the run knew about, in `ChangeSchema::LANES` order. |
| `lanes.enabled` | list of string | Lanes enabled in CHANGE.md. |
| `lanes.ran` | list of string | Lanes that ran in this scope. |
| `lanes.results.<lane>.status` | string | `pass`, `warn` or `fail` for a lane that ran. |
| `lanes.results.<lane>.findings.pass` | integer | Passing findings for the lane. |
| `lanes.results.<lane>.findings.warn` | integer | Warning findings for the lane. |
| `lanes.results.<lane>.findings.fail` | integer | Failing findings for the lane. |
| `lanes.results.<lane>.by_severity.<severity>` | integer | Findings for the lane by severity. |

## Routes

Declared routes come from the enabled lanes in CHANGE.md; exercised routes from
test-case `goto` steps and what the run reached. Matching is literal:
`/claims/123` and `/claims/:id` are different routes.

| Field | Type | Description |
| --- | --- | --- |
| `routes.declared_total` | integer | Routes declared by any enabled lane. |
| `routes.declared_exercised` | integer | Declared routes some lane or case exercised. A route whose only lane results are `not_scanned` is not exercised. |
| `routes.undeclared_exercised` | integer | Routes cases reached that no lane declares. |
| `routes.items[].path` | string | The normalized path. |
| `routes.items[].declared` | boolean | Whether any enabled lane declares it. |
| `routes.items[].declared_by` | list of string | The lanes that declare it. |
| `routes.items[].viewports` | list of string | Browserless viewports it is checked at. |
| `routes.items[].lane_status.<lane>` | string | One of `pass`, `warn`, `fail`, `not_scanned`, `no_result`, `not_declared`, `lane_off`, `n_a`. `not_scanned` means the lane ran but never loaded the route: its only findings for it are the lane's skip finding (a11y `route not scanned`, browserless `auth-required route skipped`), as after a failed login. |
| `routes.items[].cases_static` | list of string | Case ids whose steps name it. |
| `routes.items[].cases_reached` | list of string | Case ids that reached it at run time. |

## Cases

| Field | Type | Description |
| --- | --- | --- |
| `cases.defined_total` | integer | Cases defined in every configured suite. |
| `cases.selected_total` | integer | Cases the run selected. |
| `cases.counts.pass` | integer | Passing cases. |
| `cases.counts.fail` | integer | Failing cases. |
| `cases.counts.error` | integer | Cases that errored. |
| `cases.counts.skip` | integer | Skipped cases. |
| `cases.counts.warn` | integer | Cases graded warn. |
| `cases.counts.flaky` | integer | Cases that passed only after a retry. |
| `cases.counts.quarantined` | integer | Cases under quarantine. |
| `cases.counts.ungated` | integer | Cases that cannot fail the gate. |
| `cases.items[]` | per-case record | One record per selected case, at most 5000, kept failures first (see Rules). |
| `cases.truncated` | boolean | True when `cases.items` was capped. |
| `suite_inventory[].suite` | string | A suite in the configured suite files. |
| `suite_inventory[].id` | string | A case id, `suite/id`. |
| `suite_inventory[].tags` | list of string | The case's tags. |

## Findings

| Field | Type | Description |
| --- | --- | --- |
| `findings.pass` | integer | Passing findings across lanes. |
| `findings.warn` | integer | Warning findings across lanes. |
| `findings.fail` | integer | Failing findings across lanes. |
| `warnings` | list of string | Configuration and import warnings raised while recording the run. |

## Imports

Line and branch coverage and test results read from files the repo's own CI
produces. They never become findings and never gate.

| Field | Type | Description |
| --- | --- | --- |
| `imports.coverage[].label` | string | The import's label. |
| `imports.coverage[].format` | string | `cobertura`, `jacoco` or `lcov`. |
| `imports.coverage[].file` | string | The repo-relative file read. |
| `imports.coverage[].line.covered` | integer | Covered lines. |
| `imports.coverage[].line.total` | integer | Coverable lines. |
| `imports.coverage[].branch.covered` | integer | Covered branches (`branch` is null when the format reports none). |
| `imports.coverage[].branch.total` | integer | Coverable branches. |
| `imports.coverage[].groups[].name` | string | A package or directory. |
| `imports.coverage[].groups[].line.covered` | integer | Covered lines in the group. |
| `imports.coverage[].groups[].line.total` | integer | Coverable lines in the group. |
| `imports.coverage[].groups[].branch.covered` | integer | Covered branches in the group. |
| `imports.coverage[].groups[].branch.total` | integer | Coverable branches in the group. |
| `imports.coverage[].groups_truncated` | boolean | True when groups were capped at 500, lowest line coverage kept. |
| `imports.coverage[].timestamp` | string or null | When the file was produced. |
| `imports.coverage[].stale` | boolean | True when the file predates the head commit. |
| `imports.test_results[].label` | string | The import's label. |
| `imports.test_results[].format` | string | `junit` or `testng`. |
| `imports.test_results[].files` | list of string | The repo-relative files read. |
| `imports.test_results[].counts.pass` | integer | Passing tests. |
| `imports.test_results[].counts.fail` | integer | Failing tests. |
| `imports.test_results[].counts.error` | integer | Tests that errored. |
| `imports.test_results[].counts.skip` | integer | Skipped tests. |
| `imports.test_results[].counts.flaky` | integer | Tests that passed after a rerun. |
| `imports.test_results[].items[]` | per-case record | One record per test that did not plainly pass (fail, error, flaky, skip), at most 500, kept failures first (see Rules). Plain passes are only counted. |
| `imports.test_results[].truncated` | boolean | True when more than 500 tests did not plainly pass, so `items` was capped. |
| `imports.test_results[].timestamp` | string or null | When the results were produced. |
| `imports.test_results[].stale` | boolean | True when the results predate the head commit. |

## Per-case record

Shared by the testcases lane and imported JUnit and TestNG results.

| Key | Type | Description |
| --- | --- | --- |
| `source` | string | `testcases`, `junit` or `testng`. |
| `suite` | string | Suite name, JUnit testsuite name, or TestNG class. |
| `id` | string | Testcases `suite/id`; JUnit `classname#name`; TestNG `class#method`. |
| `status` | string | `pass`, `fail`, `error`, `skip` or `warn`. |
| `gated` | boolean or null | Whether the case can fail the gate; null for imported cases. |
| `attempts` | integer | Attempts made; 1 for an imported case without reruns. |
| `flaky` | boolean | Passed only after a retry or rerun. |
| `duration_ms` | integer or null | Duration in milliseconds. |
| `tags` | list of string | Case tags, or TestNG groups. |
| `message` | string or null | Failure message, whitespace collapsed, at most 300 characters. |
| `acceptance_verdict` | string or null | The graded acceptance verdict (testcases only). |
| `quarantine.reason` | string | Why the case is quarantined (`quarantine` is null when it is not; testcases only). |
| `quarantine.until` | string | The date the quarantine ends. |
| `quarantine.expired` | boolean | True once that date has passed. |
| `gotos_reached` | list of string or null | Paths the case navigated to (testcases only). |
| `landed_url` | string or null | The path a passing case ended on (testcases only). |

## Rules

- Counts are integers (`covered`, `total`); a percentage is never stored.
- A family the run did not measure is `null`, never zeros: `routes`, `cases`,
  `lanes` and `findings` are null on an import run, and `imports` is null when
  no import was configured or found. A reader shows null as "not reported".
- `repo.root` uses `~` for the home directory, so a committed copy carries no
  home path.
- A capped case list keeps cases in this order: `fail`, `error`, flaky (a
  pass that needed a rerun), `warn`, `skip`, `pass`, and file order within
  each. A failure is never dropped while a pass is kept; `counts` stay exact.
- A sweep records repo-wide imports once, on its first run (the first app in
  registry order). Its other runs carry `imports: null`. A reader showing a
  run's imports uses the run's own `imports` when present and otherwise the
  first run with the same `sweep_id` that has them.

## Merge and retention

- Runs merge by `id`: a run whose id already exists replaces it, so recording
  the same run twice is idempotent and a union-merged copy collapses back to
  one line per run.
- Retention keeps the newest `qa_report.history.max_runs` runs (default 200) by
  `recorded_at`, then `id`.
- Every write is a full rewrite under an exclusive lock on `.lock` in the same
  directory, written to a temporary file and renamed into place. A writer
  that cannot take the lock within 30 seconds skips its record with a log
  line rather than waiting.
- A line that is neither the header, the meta record, nor a parseable run
  (including one that is not valid UTF-8) is reported with its line number, and the original file is copied to
  `report-data.js.corrupt-<UTC stamp>` before the clean rewrite.

## Changing the format

- An additive, optional field keeps `Run schema: 1`. Add it to
  `ChangeCoverageSchema::FIELDS` and to a table above.
- Any incompatible change (a renamed or removed field, a changed meaning or
  type) bumps `ChangeCoverageSchema::RUN_SCHEMA` and adds an adapter for the new
  schema to the page, which keeps reading older runs through their own
  adapters.
- A change to the line layout itself bumps `ChangeCoverageSchema::FORMAT_VERSION`.
