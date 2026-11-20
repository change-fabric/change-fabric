# Principles

The rules this repo holds itself to. Each one names its enforcer: a file that
fails, denies, or tests when the rule is broken, or `advisory` when nothing
does and the rule rests on review. `scripts/docs_check.rb` fails if a principle
lacks an `Enforcer:` line or names a path that does not exist. Add a principle
only with its enforcer; prefer a rule that a machine checks.

## Hooks fail silent

A hook parses stdin through `HookEvent.read` and never crashes the session. A
missing gem, file, or credential means the hook does nothing, not that it
raises. Human-run provisioning tools (`cf_team_*`) are the exception: they
raise on a missing credential rather than half-finish.

Enforcer: scripts/hook_event.rb

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
another paid round.

Enforcer: scripts/roast.rb, scripts/roast_followups.rb, scripts/walkthrough_roast.rb, test/roast_test.rb, test/roast_followups_test.rb, test/walkthrough_roast_test.rb, skills/roast/SKILL.md, test/roast_p1_pass_test.rb

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
approval, environment and refs/cf-prod paths. An admin token can bypass hooks.

Enforcer: scripts/approval_console/local_store.rb, scripts/secrets_read_guard.rb, scripts/prod_approval_guard.rb, scripts/change_prod_gate.rb

## Only Patrick's phone approves; one Recorder writes every approval store

Agents start approvals (`--remote`, `request`; `record <id>` resumes); only a
phone passkey receipt stands, since the TOTP seed and machine key sit on the
agent's host. `ApprovalConsole::Recorder` alone writes the four stores. The
phone shows only signed fields: links, files, base, tag and commit, never agent text.

Enforcer: scripts/approval_console/proof_check.rb, scripts/approval_console/recorder.rb, scripts/secrets_read_guard.rb, approval_console/infra/lambda/pages.rb, test/approval_console_lambda_test.rb

## Approval policy comes from the base or default branch

Pins, proof level and carve-out paths come from the fetched base or default
branch after an origin repo check, never the working tree; failure fails closed.

Enforcer: scripts/change_policy.rb, scripts/approval_console/local_store.rb

## Receipts are under 24h old when recorded

Override, carve-out and release receipts also when used. Step approvals are
the only records that never expire: they are bound to sha and step digest.

Enforcer: scripts/approval_console/proof_check.rb, scripts/change_trust.rb

## Local guards are friction against an admin token

An admin token can call the merge API directly; off-machine enforcement is a
separate plan.

Enforcer: advisory

## Agents merge at the ready bar; carve-outs escalate

The coordinating agent squash-merges a PR only when it is rebased on main, CI
is green, `mergeStateStatus` is CLEAN, it has 0 unresolved review threads, and
a comprehensive `cf:change` run passed for the exact head SHA. A PR touching
the merge or tag guards, the review gate, the sensitive-term or secret hooks,
the `change_policy` block, these merge rules, or a release workflow escalates
to the maintainer; the full path list is in `CHANGE.md`. Only Patrick's phone
approves `change_approve` and `change_override`; tags go in a script under
`~/.claude/cf/manual/`. No hook checks threads or carve-out paths yet.

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

## Media is proven by playing it

A 200 on the media URL does not prove playback. A click-to-load media element
exists from the first render and starts `play()` inside the user's gesture, so
iOS Safari honors it, and a failed load surfaces an error rather than a silent
stuck player.

Enforcer: site/test/media-slot.test.ts

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
becomes a principle here with an enforcer.

Enforcer: scripts/docs_check.rb, test/docs_check_test.rb

## A walkthrough tells a story before it spends money

A walkthrough has a hero the audience recognizes as themselves, and a before, turn and after spine anchored to scenes. `validate` warns; every paid call site refuses a missing or broken story block with exit 2 before its first paid call (`--estimate-only` only warns).

Enforcer: scripts/walkthrough_story.rb, scripts/walkthrough_render.rb, scripts/elevenlabs.rb, test/walkthrough_story_test.rb, test/walkthrough_story_preflight_test.rb, scripts/walkthrough_roast.rb, test/walkthrough_roast_test.rb
