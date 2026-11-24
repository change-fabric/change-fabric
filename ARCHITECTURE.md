# Architecture

change-fabric is one repository holding five things: the cf toolkit (skills,
hooks, and the scripts behind them), the `CHANGE.md` spec, the marketing and
spec site, the telemetry backend, and the account-level AWS monitoring. The
rules the repo holds itself to are in `PRINCIPLES.md`; the release runbook is
`RELEASING.md`.

## Directory map

| Path | What it is |
| --- | --- |
| `skills/` | Skill sources, one directory per skill. Read at runtime by every installed host. |
| `scripts/` | Ruby behind the skills and hooks: guards, the `cf:change` lanes, renderers, the runtime and CLI. |
| `install.rb` | Makes the live install match this checkout for every host. Re-run after pulling. |
| `workflows/modes/` | Host-neutral merge-mode contracts that the skill compiler renders per host. |
| `config/` | `host_capabilities.json` (per-host evidence registry) and `providers.yml` (paid API providers). |
| `extensions/` | TypeScript adapters for Pi and OpenCode, sharing one client in `extensions/shared/`. |
| `test/` | Minitest suite, `test/*_test.rb`, run by `rake test`. |
| `site/` | The Vite site at www.changefabric.org, its spec archive in `site/src/archive/`, and `site/infra/`. |
| `telemetry/` | The `api.changefabric.org` backend: Terraform in `telemetry/infra/`, Lambdas under it. |
| `account/infra/` | Account-wide alarms, CloudTrail, budgets, and security controls. Owns no workload. |
| `approval_console/` | The remote approval console: Terraform in `approval_console/infra/`, the Lambda under it. |
| `walkthrough/` | Walkthrough sources for the site's own video. |
| `platform/` | An earlier hosted app and its infra. Under review for removal; do not build on it. |
| `CHANGE.md` | This repo's own `cf:change` config and policy. |

## The toolkit

A skill is a directory under `skills/` with a `SKILL.md` and optional
reference files. `install.rb` links or generates each skill into every host's
discovery directory, copies `scripts/` to `~/.claude/cf/bin/`, and wires the
hooks into each host's settings. It records what it wrote in
`~/.local/share/change-fabric/installation.json`, so `cf uninstall` removes only
unchanged files it owns.

### Hooks

Wired by `install.rb` per lifecycle event (Claude Code names shown):

| Event | Scripts |
| --- | --- |
| SessionStart | `skill_detect.rb`, `ctx_session_start.rb`, `doctrine_digest.rb`, `secret_alert_poll.rb` |
| PreToolUse | `secrets_read_guard.rb`, `client_name_guard.rb`, `slop_remind.rb`, `review_gate.rb`, `noreply_guard.rb`, `docker_doctrine_guard.rb`, `change_merge_guard.rb`, `change_tag_guard.rb`, `change_stale_remind.rb`, `presence_probe.rb`, `prod_approval_guard.rb`, `model_role_guard.rb`, `resource_floor_guard.rb` |
| PostToolUse | `skill_inject.rb`, `secret_ack.rb`, `change_post_merge_check.rb`, `pulse_stamp.rb` |
| UserPromptSubmit | `key_paste_guard.rb`, `prune_remind.rb`, `inbox_prompt_hook.rb` |
| SessionEnd | `telemetry_emit.rb`, `inbox_session_end.rb` |
| Stop | `skill_review.rb`, `pulse_stamp.rb` |
| SubagentStart, SubagentStop | `pulse_stamp.rb` (claude only) |

`pulse_stamp.rb` is wired by `native_hook_install.rb` as its own command (not
through `cf_host_hook.rb`). It stamps activity into the session record and
records engage triggers; it speaks only when `Pulse::ACTIVATED` is true and every
`Pulse::READY_PARTS` entry is installed.

Pulse reviews a long run for integrity as well as liveness. Phase agents in a
cf:plan workflow emit `phase_boundary` events (`pulse_watch.rb emit`); a plan
permits pulse's own acts with a `pulse-allow: nudge_worker, stop_runaway` line
in plan.md, and `/cf:pulse off` opts a session out. Deterministic integrity
checks (`pulse_integrity.rb`) run with no model and keep running after the
budget is spent; only a P0 integrity finding interrupts the human.

Every hook reads its event through `scripts/hook_event.rb` and fails silent.
SessionStart hooks state rules up front (`doctrine_digest.rb` holds the
session-global tenets as a Ruby constant, kept in sync with `PRINCIPLES.md` by
`test/docs_check_test.rb`). PreToolUse guards deny after the fact. The two
change guards share their gate question through `scripts/change_gate_check.rb`.
Terminal approvals add a TOTP second factor: `scripts/approval_console.rb`
(`totp-enroll`, `status`, `unlock`) and `scripts/approval_console/` keep the seed
and replay fence under the cf secret store; `change_approve.rb` and
`change_override.rb` store a `totp-terminal` proof beside the record.
Bounded prod ops: an agent files a cf.prod.request/1 envelope
(`change_prod_request.rb`, state in refs/cf-prod git refs); a human approves
its digest (`change_prod_approve.rb`); `change_prod_runner_gen.rb` generates
the cf-prod workflow, whose jobs verify the approval offline through
`change_prod_gate.rb` and claim it once (a conditional put in the approval console's table, never a git ref) before any credential. This release
emits staging only and has no op executor; `prod_approval_guard.rb` denies the
agent the approval paths. `change_prod_classes.rb` reports op classes for doctor
and the request notice, and links them to `one_way_doors` paths.
`change_prod_redeploy.rb` holds the built-in `redeploy_previous` op and the
rollback request triage files (the predecessor sha is bound into the digest;
tags stay human-only).
`change_backup.rb` takes and verifies the fresh snapshot, measures PITR and runs
the restore probe, and its gate refuses an op on thin recovery evidence;
`change_backup_probe_gen.rb` generates the weekly restore-probe workflow.
Rubric skills are matched to edited files by `skill_detect.rb` and
`skill_inject.rb`, queued, and reviewed at Stop by `skill_review.rb`.

### Host portability

One workflow intent, explicit adapters per host. `install.rb` wires Claude Code
(native hooks), Codex (a native hooks file plus generated `cf-*` skills under
`~/.agents/skills`), Copilot CLI (a user-level hook file), OpenCode (a plugin),
and Pi (an extension). All adapters call `scripts/cf_host_hook.rb`, which maps
each host's payload onto `scripts/cf_runtime.rb`, a JSON-in, JSON-out protocol
keyed by host, canonical project root, and session id. Mode state lives under
`~/.local/state/change-fabric` (or `CF_STATE_HOME`). Shared skill prose uses
`{{skill:name}}` references that the skill compiler renders into each host's
invocation syntax, so Codex users type `$cf-roast`, not `/cf:roast`.
`config/host_capabilities.json` records documented features and the exact
versions with tested evidence; unknown versions stay unverified.
`cf doctor --host HOST` reports installed files and adapter config without
running a model. Guards are advisory policy, not a sandbox.

#### Model roles

Skills name a role, never a tier. `config/model_roles.yml` maps each role
(orchestrator, worker, author, critic, classifier) to a model per host, and
`scripts/model_roles.rb` resolves it once at install time (env `CF_MODEL_<ROLE>`,
then the user file, then the repo map). `install.rb` renders `{{model:<role>}}`
in skill prose and `model: {{model-js:<role>}}` in Workflow JS through
`scripts/skill_compiler.rb`, then writes the resolved snapshot last. The
advisory hook `scripts/model_role_guard.rb` and the acceptance grader read
that snapshot only, so they agree with the skills as installed; `cf doctor`
and `install.rb` print drift. The hook warns, never blocks, when a spawn
tagged `[role:<role>]` has a different model or none, and covers only Agent
spawns written as skill prose. Workflow `agent()` calls are not reachable by
that hook (the runtime makes them, not an Agent tool call), so
`test/model_roles_lint_test.rb` lints them statically. The grader adds
`--model` for the critic to its default `claude -p` command only, never to a
`CF_ACCEPTANCE_GRADER` override. `scripts/roast.rb` and `scripts/roast_codex.rb`
stay outside the map; they choose an OpenAI model themselves.

### cf:change

The release-gate sweep. One root `CHANGE.md` per governed repo, whose
frontmatter carries `change_config:` and `change_policy:`. Six lanes: five
dockerized audit lanes (k6, axe-core, ZAP, browserless responsive UX, committed
test cases) and a host-run command lane. `scripts/change_run.rb` runs them,
writes the report, and records a pass or fail for the head SHA that the merge
and tag guards read. The full contract is `skills/change/SKILL.md`; the
frontmatter spec is `skills/change/reference/CHANGE-frontmatter-spec.md`, whose
version is `ChangeSchema::VERSION` in `scripts/change_schema.rb`.

## Release model

Merging to `main` stages work. Nothing ships until a human pushes a tag. Three
tracks, three tag namespaces, no shared cadence:

| Track | Version source | Tag | Publishes |
| --- | --- | --- | --- |
| Toolkit | the tag itself, no file | `skills/vX.Y.Z` | GitHub Release, then the Homebrew tap bump |
| Spec | `ChangeSchema::VERSION` | `spec/vX.Y.Z` | GitHub Release from the `CHANGELOG.md` section |
| Site | `site/VERSION` | `site/vX.Y.Z` | Production deploy, no GitHub Release |

The tracks change at different rates for different consumers, so none waits on
another. Each publish workflow checks its tag before publishing:
`release-skills.yml` requires plain semver strictly above every `skills/v*` tag
(integer field sort, prereleases rejected); `release-spec.yml` requires the tag
to match `ChangeSchema::VERSION`, the spec doc's `Schema version` line, and a
`CHANGELOG.md` section; `deploy-site.yml` requires the tag to match
`site/VERSION` and the spec version it publishes to be released already. The
site keeps its version file for now, an acknowledged asymmetry with the
toolkit. The pre-2026 `change-schema/v*` tags are frozen history. The steps for
each track are in `RELEASING.md`.

## Infrastructure

Five Terraform roots share one state bucket under separate keys:
`site/infra`, `telemetry/infra`, `account/infra`, `approval_console/infra`, and
`platform/infra` (under review). `account/infra` references the others by literal identifier only, so
it applies regardless of their state. Each root's README covers its apply.

## Docs policy

The living set is `ARCHITECTURE.md`, `PRINCIPLES.md`, `AGENTS.md`, and
`RELEASING.md`, plus `README.md`, `CHANGELOG.md`, `CHANGE.md`, the site and
infra READMEs, and the skill and walkthrough files in the shapes they use (`SKILL.md`,
reference files, briefs, storyboards). `scripts/docs_check.rb` holds the
allowlist and runs in `rake test`; a stray notes file or roast log fails it.

## History

Superseded docs (the docs directory, the RELEASING decision records, the host
compatibility notes, two RCAs, roast logs, and the lambda READMEs) were removed
by the living-docs PR. Read them with `git show <commit>^:<path>` on that
squash commit.
