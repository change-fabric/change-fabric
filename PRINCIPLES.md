# Principles

The rules this repo holds itself to. Each one names its enforcer: a file that fails, denies, or tests when the rule is broken, or `advisory` when nothing does and the rule rests on review. `scripts/docs_check.rb` fails if a principle lacks an `Enforcer:` line or names a path that does not exist. Add a principle only with its enforcer; prefer a rule that a machine checks.

## Hooks fail silent

A hook parses stdin through `HookEvent.read` and never crashes the session. A missing gem, file, or credential means the hook does nothing, not that it raises. `cf_team_*` tools raise instead. Resource gates fail closed; the spawn hook only warns.

Enforcer: scripts/hook_event.rb, scripts/resource_gate.rb

## Containers, not host daemons

Project services (datastores, proxies, runtimes) run in dedicated Docker
containers, never as Homebrew or host daemons. Escape hatch:
`CF_ALLOW_HOSTDAEMON=1`. The full rubric is `skills/docker/SKILL.md`.

Enforcer: scripts/docker_doctrine_guard.rb

## No slop glyphs in authored prose

Commits, PRs, comments, and docs carry no em-dash, bullet glyph, ellipsis, or
smart quotes. `scripts/slop_remind.rb` prompts at git and gh authoring time;
the glyph set is `PlanCheck::GLYPHS`, which also fails plans and the living
docs. Product copy in a downstream repo follows that repo's own rules.

Enforcer: scripts/plan_check.rb, scripts/docs_check.rb

## Short PRs

PR titles are at most 60 characters. Descriptions are at most 640 characters
unless a code snippet or test-plan checklist needs more, and the core
description still fits in 640. `scripts/slop_remind.rb` prompts at
`gh pr create` and `gh pr edit`; nothing denies.

Enforcer: advisory

## One roast stop rule

cf:roast and the fidelity loop share one stop rule: a P0 continues until the
cap, the cap stops with the P0 reported as blocking, a score of 8 or more with
no P0 stops, otherwise continue. Open P1s become local follow-ups, never
another paid round. The outbound roast floor is 8 (`roast_target` 8 to 10, up
to 5 rounds).

Enforcer: scripts/execution_config_schema.rb, test/execution_config_schema_test.rb, scripts/roast.rb, scripts/roast_followups.rb, scripts/walkthrough_roast.rb, test/roast_test.rb, test/roast_followups_test.rb, test/walkthrough_roast_test.rb, skills/roast/SKILL.md, test/roast_p1_pass_test.rb

## Push is gated on a design review

A push or PR is denied until the files changed this session have a completed
design review. Run the review the gate hands back, then
`ruby ~/.claude/cf/bin/review_ack.rb <session_id>`. The round cap (5) releases
a batch that is denied unchanged five times in a row.

Enforcer: scripts/review_gate.rb

## No client names in this repo

The toolkit is shared across projects, so authored output here names no
client, customer, or downstream project. Terms live in the user's own
`~/.claude/cf/sensitive_terms.txt`, never committed. The guard is scoped to
this repo's remote. Escape hatch: `CF_ALLOW_SENSITIVE_TERM=1`.

Enforcer: scripts/client_name_guard.rb

## Protected merges and tags pass cf:change first

A `gh pr merge` into a protected branch, or the push of a protected release
tag, needs a passing comprehensive `cf:change` run for the head SHA and the
repo's admin-bypass policy. Only repos with a root `CHANGE.md` are governed.
`CF_ALLOW_UNGATED_MERGE=1` works only if exported before the session started;
otherwise a human runs `ruby ~/.claude/cf/bin/change_override.rb <sha> --reason`
from a real terminal.

Enforcer: scripts/change_merge_guard.rb, scripts/change_tag_guard.rb, scripts/change_gate_check.rb

## Terminal approvals need a one-use TOTP code

`change_approve.rb`, `change_override.rb` and `change_prod_approve.rb` need a
one-use TOTP code and refuse without a TTY or in an agent harness. Prod ops run
only via the generated cf-prod workflow: the runner verifies approval offline, a
terminal proof is staging only, and `prod_approval_guard.rb` denies agents the
approval, environment and refs/cf-prod paths. Every op class needs both factors.
An admin token can bypass hooks. cf:incident runs no prod command or tag push.

Enforcer: scripts/approval_console/local_store.rb, scripts/secrets_read_guard.rb, scripts/prod_approval_guard.rb, scripts/change_prod_gate.rb, scripts/change_prod_classes.rb, test/incident_skill_test.rb

## Only Patrick's phone approves; one Recorder writes every approval store

Agents start approvals (`--remote`, `request`; `record <id>` resumes); only a
phone passkey receipt stands, since the TOTP seed and machine key sit on the
agent's host. `ApprovalConsole::Recorder` alone writes the five stores. The
phone builds links only from signed fields; agent text shows in a separate
unverified zone. Tags push only after a phone release approval of the exact tag
and commit. A queued script runs only through `scripts/cf_run_approved.rb`: the phone
saw its full text, the receipt is single-use and 15 minutes old at most.

Enforcer: scripts/change_tag_guard.rb, scripts/cf_run_approved.rb, scripts/prod_approval_guard.rb, scripts/approval_console/proof_check.rb, scripts/approval_console/recorder.rb, scripts/secrets_read_guard.rb, approval_console/infra/lambda/pages.rb, test/approval_console_lambda_test.rb, test/approval_console_pages_test.rb, test/cf_run_approved_test.rb

## Approval policy comes from the base or default branch; receipts are fresh

Pins, proof level and carve-out paths come from the fetched base or default
branch after an origin repo check, never the working tree; failure fails closed.
Receipts are under 24h old when recorded; override, carve-out and release ones
also when used. Only step approvals never expire (bound to sha and step digest).

Enforcer: scripts/change_policy.rb, scripts/approval_console/local_store.rb, scripts/approval_console/proof_check.rb, scripts/change_trust.rb

## Human gates are watched by a background task

Every human gate an agent opens (phone approval, CI wait, review request) is
watched by a background task that ends on approve, deny or expire and wakes the
agent, which then records and acts. No fire-and-forget, no blocking the turn,
no asking the human to type "approved". For approvals the watcher is the
agent's own `approval_console.rb record <id>` run with `run_in_background`: it
records on approval and exits 3 (denied) or 4 (expired). `request` never
spawns a detached watcher; that would be a host daemon.

Enforcer: scripts/approval_watch_remind.rb, scripts/doctrine_digest.rb, scripts/approval_console.rb, test/approval_watch_remind_test.rb, test/approval_console_cli_test.rb

## Local guards are friction against an admin token

An admin token can call the merge API directly; off-machine enforcement is a
separate plan.

Enforcer: advisory

## Agents merge at the ready bar; carve-outs need a phone-approved head

The coordinating agent squash-merges a PR only when it is rebased on main, CI
is green, `mergeStateStatus` is CLEAN, it has 0 unresolved review threads, and
a comprehensive `cf:change` run passed for the exact head SHA. A PR touching
the merge or tag guards, the review gate, the sensitive-term or secret hooks,
the `change_policy` block, these merge rules, or a release workflow is a
carve-out (paths in `CHANGE.md`): the merge guard merges it only at the head
Patrick's phone approved, with `--match-head-commit <sha>`, failing closed on
a gh error.

Enforcer: scripts/change_merge_guard.rb, CHANGE.md

## One PR at a time, rebased, linear history

A sweep lands PRs serially: only the head of line (the first unmerged PR in
the recorded queue) is rebased, driven, gated, handed off, or merged, and the
next is touched only after gh confirms the merge. Change Fabric prefers rebase
over merge and keeps history linear (squash or rebase, never a merge commit),
regardless of what a repo's own branch protection allows. Each merge puts the
rest BEHIND, and a rebase throws away their SHA-keyed CI and cf:change gate.

Enforcer: scripts/stack_store.rb

## Merging stages, a human tag releases

Nothing ships on merge. Each track releases when a human pushes its tag; no
workflow pushes a tag (a tag pushed with `GITHUB_TOKEN` would not trigger the
publish workflow anyway). Every publish workflow validates its tag before it
publishes anything.

Enforcer: .github/workflows/release-skills.yml, .github/workflows/release-spec.yml, .github/workflows/deploy-site.yml

## The toolkit has no version file

The `skills/vX.Y.Z` tag is the version. A toolkit PR bumps nothing. The tag must
be plain semver, newly created, and strictly above every existing `skills/v*`
tag, compared field by field as integers. The tag bumps the Homebrew tap with
no PR, and a daily check alarms while the tap trails the newest tag.

Enforcer: .github/workflows/release-skills.yml, .github/workflows/bump-tap-formula.yml, .github/workflows/tap-drift.yml

## The site may lag a spec release, never lead one

A spec release never deploys the site. A site deploy fails unless the spec
version it would publish as current already has its `spec/v*` tag. Order:
merge, push `spec/vX.Y.Z`, then push `site/vA.B.C`.

Enforcer: .github/workflows/deploy-site.yml

## A host is supported only when tested on that host

Copying a skill into a host's directory is not support. Each host needs its
own discovery, invocation, and lifecycle contract, with tests, before any doc
claims it works. A fixture pass is never reported as a live model pass, and
`not-run` is not a pass.

Enforcer: test/install_test.rb, test/agent_contract_test.rb

## Media and fixes are proven in a real browser

A 200 on a media URL does not prove playback, and a mocked unit test does not
prove a UI fix. A click-to-load media element starts `play()` inside the user's
gesture, and a UI fix ships with a suite case whose measured read fails on the
base and passes on the head.

Enforcer: site/test/media-slot.test.ts, test/change_measured_shapes_docker_test.rb

## Autopilot relaxes gates, never the core; force-push to trunk is denied in every mode

Autopilot is a phone-approved receipt for one repo and machine with a signed end at most 72h out; until that end or `change_autopilot.rb end` it waives only the gates it lists (carve-out taps off locked paths, review rounds, host-daemon, sensitive-term), logging each waiver, and it never reads or changes the merge mode. Secrets, release tags, change_override, CF_ALLOW_UNGATED_MERGE, cf:change passes and trunk force-push, rewrite or deletion stay locked; the force-push guard has no escape hatch.

Prod is covered only with a recovery precondition. Under an autopilot that lists `prod`, the runner needs no per-action tap, but any statement outside an allowlist (SELECT, SHOW, INSERT ... VALUES, UPDATE or DELETE with a WHERE, BEGIN, COMMIT, ROLLBACK, SET; never EXPLAIN, DO, CALL, COPY or DDL), a statement estimated over the op's row threshold, and any SQL the scanner cannot read with certainty (double quotes, dollar quotes, escape strings, control or non-ASCII characters) runs only after a verified recovery artifact: an available snapshot, or a dump with a recorded sha256 and per-table row counts. With none it is denied, and every run writes an audit record with statement hashes, row counts and the artifact id. A per-action approval keeps today's rules.

Enforcer: scripts/change_autopilot.rb, scripts/force_push_guard.rb, scripts/change_prod_recovery.rb, scripts/change_prod_sql.rb, scripts/change_prod_gate.rb

## Skills name roles, not tiers

Skills write `{{model:<role>}}` in prose and `model: {{model-js:<role>}}` in
Workflow JS, never a tier name, and every Workflow `agent()` call carries a
model option. An exception needs a `model-roles: allow <reason>` marker listed
in `MARKER_EXCEPTIONS`. A tagged spawn that misses its role warns at run time.

Enforcer: test/model_roles_lint_test.rb, scripts/model_role_guard.rb

## Docs are the living set only

Architecture lives in `ARCHITECTURE.md`, rules here, agent instructions in
`AGENTS.md`, the release runbook in `RELEASING.md`. A new markdown file outside
the allowlist in `scripts/docs_check.rb` fails `rake test`. Decision records,
RCAs, and review logs go in the PR and git history, and any lasting lesson
becomes a principle here with an enforcer. Incident RCAs live outside git. A client incident report is drafted, scanned and roasted, and only a human sends it.

Enforcer: scripts/docs_check.rb, test/docs_check_test.rb, scripts/incident_store.rb, scripts/incident_report.rb, test/incident_report_test.rb

## A walkthrough tells a story before it spends money

A walkthrough has a hero the audience recognizes as themselves, and a before, turn and after spine anchored to scenes. `validate` warns; every paid call site refuses a missing or broken story block with exit 2 before its first paid call (`--estimate-only` only warns).

Enforcer: scripts/walkthrough_story.rb, scripts/walkthrough_render.rb, scripts/elevenlabs.rb, test/walkthrough_story_test.rb, test/walkthrough_story_preflight_test.rb, scripts/walkthrough_roast.rb, test/walkthrough_roast_test.rb, scripts/key_project.rb, test/key_project_test.rb

## A run is reviewed for integrity, not just liveness

A long run is checked for a pass that proves nothing, not only for a worker that is alive. Deterministic checks flag a zero-row PASS, skipped counted as pass, a narrowed run called comprehensive, and a gate not bound to the head SHA, with no model call. A P0 integrity finding interrupts the human; everything else is queued. Pulse acts alone only inside the `pulse-allow:` line of the plan.

Enforcer: test/pulse_integrity_test.rb, scripts/pulse_integrity.rb

## A scheduled flag matrix never leaves a flag on

`scripts/scheduled_lane.rb` flips one flag at a time in a non-production env. It refuses production, writes a revert ledger row before each flip, restores the seed state on any error or trapped signal, and sweeps leftovers first. A scheduled run only detects, and a revert needs a decided dispatch or a standing receipt.

Enforcer: test/scheduled_lane_flag_matrix_test.rb, scripts/scheduled_lane/flag_matrix.rb
