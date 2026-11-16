---
name: cf:overnight
group: workflow
description: Unattended overnight build, ship and validate cycle for a project, ending in numbered cf:walkthrough drafts. Reads the repo's own rules into a typed capability manifest, asks four decisions once, then ships units one at a time under every existing gate. Execution is disabled in this release; only --dry-run runs, printing the manifest with sources, denials, adopted units, and every command it would run.
---

# CF Overnight

Hand a project to the agent at night and wake up to shipped, validated work.
Every existing safety gate (merge mode, cf:change, tag guard, review gate)
stays in force; overnight runs them unattended.

Trigger: `/cf:overnight <goal or plan dir> [--dry-run] [--no-walkthrough] [--budget-usd N] [--stop-on destructive|never]`.

## Status: dry-run only

Execution is disabled. `OVERNIGHT_EXECUTE_ENABLED` in
`scripts/overnight_store.rb` is false, and every executing path refuses with
exit 3. It turns on only in the release that lands the fake-provider harness.
Until then this skill does intake, the dry-run and the gates below, and
nothing else. Do not push, merge, tag, deploy, change a flag or make a paid
call on its behalf.

## Dry-run

```
ruby ~/.claude/cf/bin/overnight_plan.rb --dry-run --repo <repo> [--plan <plan dir>] [--mode local-only|merge-ready|admin-bypass|yolo] [--budget-usd N] [--no-walkthrough]
```

Pass the session merge mode as `--mode` (default `local-only`). The output is
byte-stable and secrets are masked. It prints:

1. The manifest: every field with its value and source (`file:line` or
   `default`), safety fields marked.
2. Denials: missing, conflicting or invalid safety fields, and each
   capability allowed or denied with the reason.
3. The interview: the four decisions as they would be asked.
4. Units: new or adopted (PR, branch, worktree), with dependency edges.
5. A schedule per unit: step, command, gate, expected outcome, deadline.
6. Reservations against the budget, and the wakeup and Monitor plan.

The dry-run path never builds an executor. Its only process calls are the
read-only discovery allowlist: `git log`, `git worktree list`, `git ls-remote`,
`gh pr list`, `gh run list`. Adapter tests, enrollment, backups and probes
appear as planned commands with their unresolved preconditions, never run.

## Intake: the capability manifest

`scripts/overnight_plan.rb` resolves a typed manifest from the repo. Precedence,
highest first: `CHANGE.md` frontmatter, `AGENTS.md`, `CLAUDE.md`, `docs/**/*.md`,
planner default. A prose file declares a field with one line:

```
overnight.flags_adapter: bin/flags
```

`CHANGE.md` contributes what its frontmatter already states: the trunk
(`change_policy.gate.trunk`), the production tag rule (the `tag:` promotion
whose environment is production) and that rule's profile lanes.

Safety fields: `agent_tags_allowed`, `production_lanes`, `flags_adapter`,
`terraform_wrapper`, `migration_command`, `expand_only_marker`,
`maintenance_command`, `backup_provider`, `credential_isolation`. A safety field
that is missing, invalid, or stated differently by two sources is a capability
denial for every step that needs it. It is never guessed and never defaulted.

Capabilities and what denies them:

| Capability | Needs | Also denied when |
|---|---|---|
| production-tag | agent_tags_allowed, production_lanes | agent tags forbidden; production lanes include k6 or zap (unit goes staging-only) |
| flags | flags_adapter | adapter untested (flagless path) |
| terraform | terraform_wrapper | |
| migrations | migration_command, expand_only_marker | |
| destructive | backup_provider, maintenance_command, credential_isolation, migration rules | no credential isolation inside the executor |

After the interview the manifest plus answers freeze to `policy.json` with its
sha256. Each wakeup re-resolves; a changed hash invalidates every
not-yet-dispatched step that depends on a changed field, and the unit goes to
handed-over.

## Interview: once, then away

One AskUserQuestion with four questions, shown beside the resolved schedule
and the denied capabilities:

1. Destructive writes: full guard (verified backup, test restore, provider
   snapshot, maintenance window) first, then never, then staging only. Forced
   to never when the destructive capability is denied.
2. Scope and order.
3. Flag state after ship.
4. Walkthrough end state: numbered drafts overnight, final in the morning.

Keys and spend estimates are checked at intake (`cf_keys.rb` status, never
enroll), so no key question fires at night. Then run `/cf:away`. After that
only the five away floor questions may be asked.

## State, journal and lease

`scripts/overnight_store.rb` keeps each run under
`~/.claude/cf/overnight/<repo>/<run-id>/`: `state.json`, `journal.jsonl`,
`policy.json`, `lease.json`.

1. Every side effect is an action `<unit>:<step>:<attempt>` with journal
   records `planned` (intent plus idempotency key, before the request),
   `dispatched` (external ids), `observed-complete` (evidence), or
   `uncertain`. The per-kind protocol is `reference/dispatch.md`.
2. Resume reconciles every nonterminal action first. An uncertain dispatch of
   a kind with no idempotency and no lookup blocks that unit.
3. A corrupt state or journal blocks every mutation; it is never moved aside.
4. The lease carries a fencing token that only grows. A write with a stale or
   expired token is refused. Takeover only after expiry; with any
   nonterminal action (a planned one may already have reached the remote) it
   is granted in reconcile mode, which plans nothing new until every action
   is reconciled.
5. Ownership lock: the run takes the repo's ACTIVE claim shared with
   cf:sweep stack mode, plus a per-target lock. A second run id on the same
   target is refused.
6. `resume` with no run id picks the only unfinished run and refuses when
   there are several.

## Gates

- ON-1: one unit at a time under the fenced lease; next unit only per the next-unit rule.
- ON-2: no question after the interview except the five away floor questions; keys and estimates validated at intake.
- ON-3: merge only per merge mode and SW-2; yolo refused where the repo protects its trunk.
- ON-4: production tag only via `change_tag_guard.rb`, agent tags allowed, no k6 or ZAP in the production profile; else staging-only.
- ON-5: destructive writes only through the executor with a valid authorization record.
- ON-6: never roll back a migration; retag only through the rollback eligibility gate.
- ON-7: every step decided by the transition table; counters bounded.
- ON-8: every paid call reserved at its max charge; no reservation, no call.
- ON-9: no external posts, no secrets, Terraform and migrations only via declared wrappers.
- ON-10: no smoke before deploy identity and deployed-version check pass.
- ON-11: missing or conflicting safety policy is a capability denial; policy hash change invalidates affected actions.
- ON-12: mutation disabled until the enablement gate (harness green) is set.

## Merge modes

| Mode | What overnight does |
|---|---|
| admin-bypass | the full loop |
| merge-ready | readies the head unit, arms `stack_watch.rb`, continues if the human merges, else hands over in the morning |
| local-only | builds, tests and dry-runs only |
| yolo | refused where the repo protects its trunk |
