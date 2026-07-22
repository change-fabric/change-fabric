---
name: pst:change
description: Deterministic, config-driven release-gate sweep. Runs all four dockerized audit lanes (k6 load, axe-core accessibility, OWASP ZAP pentest, browserless responsive UX) against a project's change-fabric config, aggregates every finding into one CSV and Markdown report on the Desktop, and records a pass/fail gate for the head commit. Invocable directly and gated into pst:drive.
---

# PST Change (change fabric)

The comprehensive, unattended release-gate sweep. One file per project, the
repo-root `CHANGE.md`, tells the platform how to boot the target app and what to
audit (its `change_config:` frontmatter) and how the repo is governed (its
`change_policy:` frontmatter); this skill runs all four dockerized lanes against
it and produces one shareable report pair plus a gate record for the PR's head
commit.

Trigger: `/pst:change [<PR, branch, or target description>]`.

Question: would this change survive a release-quality sweep of load,
accessibility, security, and responsive UX, deterministically and on the record?

## pst:change vs pst:qa

Both drive browsers in an ephemeral browserless container, but they are
different tools:

- `pst:qa` is ad hoc, model-scoped, natural-language-driven. It scopes a
  Playwright smoke plan from a described flow, clarifies ambiguity with the
  user, and explores. Use it for exploratory UAT of a specific feature.
- `pst:change` is deterministic and config-driven. It reads the repo-root
  `CHANGE.md` and runs a fixed four-lane audit (load, a11y, security, responsive
  UX) with no per-run scoping decisions, meant to run unattended before a
  release-affecting merge. It writes a reproducible report and records a
  pass/fail gate the merge hook enforces.

Reach for `pst:qa` to investigate; reach for `pst:change` to gate.

## The single project file

A change-fabric-integrated repo carries one file, the repo-root `CHANGE.md`,
whose frontmatter holds two blocks that split cleanly:

- `change_config:`: the mechanical target-app config (boot command, health
  check, routes, ZAP scope, k6 thresholds, viewports). See "Config schema".
- `change_policy:`: the machine-checkable governance the merge gate reads
  (protected branches, per-environment promotion rules, admin-bypass policy).

The prose body below the frontmatter is the narrative change-management FAQ (git
flow, promotion, self-review, when admin-bypass merging is acceptable) a teammate
is pointed at. `reference/CHANGE.template.md` is the annotated starting point,
config and policy in one file. The merge-gating hook reads the `change_policy:`
block to decide whether a merge into a protected branch is allowed for the head
SHA; the lanes read the `change_config:` block.

## Workflow

1. **Resolve scope.** A PR (read its head, check it out so the run happens on
   the head commit), a branch, or a target description. The gate record is keyed
   by the git head SHA, so run against the exact commit that will merge.
2. **Confirm the config.** Ensure a `CHANGE.md` with a `change_config:`
   frontmatter block exists at the target repo root. If it does not, this repo is
   not change-fabric-integrated yet; say so and stop rather than guessing an
   audit surface. Scoping a target from a description follows pst:qa's phase 1-5
   shape only where the config leaves a choice open; the config is the source of
   truth for what to audit. `CHANGE.md` must be self-contained: reject or flag a
   config that cites another tool's own internal conventions (a coding harness's
   config vocabulary, an unrelated CLAUDE.md table) instead of stating the
   target app's own boot and audit details directly.
3. **Run the sweep.** From the target repo root:
   `ruby ~/.claude/pst/bin/change_run.rb all`. This boots the app per the
   config, waits for its health signal, stands up the ephemeral runners
   (digest-pinned, `--rm`, per pst:docker), runs k6, a11y, ZAP, and browserless
   lanes, tears everything down, writes the report pair to `~/Desktop`, and
   records the gate under the head SHA. Exit 0 means every lane passed, 1 means
   a lane failed, 2 means a setup failure (no docker, bad config, app never
   ready).
4. **Report.** Summarize the per-lane pass/fail and the failing findings from
   the Markdown report. Name both report paths (the `.md` and the `.csv`) so the
   run is reproducible and shareable.

## Config schema

The `change_config:` frontmatter block of `CHANGE.md` (YAML; comments allowed).
See `reference/CHANGE.template.md` for the annotated, copyable reference (config
and policy together). Shape under `change_config:`:

- `project`: label used in the report filename.
- `boot`: `up` (boot command, e.g. `docker compose up -d --build ...`), `down`
  (teardown command), `network` (an existing docker network the runners join;
  omit to create an ephemeral one and reach the app via `host.docker.internal`),
  `target_url` (in-network base url the lanes default to), and `health`
  (`url` host-reachable, `expect_status`, `timeout_seconds`).
- `lanes.k6`: `enabled`, `script` (repo-relative k6 script; omit for the
  built-in light-load default), `env`, `thresholds` (`http_req_failed`,
  `http_req_duration`).
- `lanes.a11y`: `enabled`, `routes`, `threshold`
  (`minor|moderate|serious|critical`, default `serious`), optional `base_url`.
- `lanes.zap`: `enabled`, `targets` (list of in-scope urls), `strict` (fail on
  any low-or-above alert; default fails only on high-risk), optional `auth`
  (reserved for authenticated scans; the baseline runs unauthenticated).
- `lanes.browserless`: `enabled`, `routes` (a plain string, or a mapping with
  `path` plus optional `auth: true` and a `figma: {file_key, node_id}` block),
  `viewports` (`name`/`width`/`height` list), optional `base_url`, an `auth:`
  block (real login-flow credentials read from named env vars, never
  hardcoded) that runs once per session before any `auth: true` route, and a
  `figma:` block (`token_env`, `max_diff_percent`) for the pixel-diff check
  against a real Figma REST API reference render. A login needing more than
  one form (an OTP flow: submit an email, then a code from a second form)
  uses `auth.steps` instead of the single-form shorthand; a step's field value
  comes from an env var or a `code_source` that polls an HTTP endpoint (e.g. a
  Mailpit dev inbox) for the code live, never reading or storing a real OTP on
  the host. See
  "Config schema" -> `reference/CHANGE-frontmatter-spec.md` for the full field
  set.

A lane a project does not want is omitted or set `enabled: false`. A project can
carry the config alone with none of the tools installed as repo dependencies.

## Policy (CHANGE.md body and `change_policy:`)

`reference/CHANGE.template.md` is the template. Below its two frontmatter blocks
it is a governance FAQ: the `change_policy:` frontmatter block is
machine-checkable, and the prose body answers, per environment, in plain
language:

- What is required before a change promotes to each environment (which
  promotion stages require a merge review, which do not).
- Who may review, and whether self-review (the author approving or merging their
  own work, including a tech lead reviewing their own change) is allowed and
  under what conditions.
- When admin-bypass merging (skipping the normal review/CI wait) is and is not
  acceptable, stated as a direct answer, not "sometimes".
- What CI gates at each promotion stage, and whether that gate is ever
  skippable.

The prose is the truth a teammate reads; the frontmatter states the same policy
in the form the merge gate enforces.

## Lane subsets

The single-lane skills run one lane each with the same config and report
shape but record only their own scope (never the comprehensive gate the merge
hook requires): `pst:k6`, `pst:a11y`, `pst:zap`. The browserless responsive
lane has no standalone skill; it runs as part of `pst:change`.

## Failure modes

- Docker unavailable, or a runner image cannot be pulled: `change_run.rb` exits
  2 and names the cause. Report it and stop; never fall back to a host daemon.
- No `CHANGE.md` with a `change_config:` block: the repo is not integrated. The
  error names the template and spec doc to author one against. Run
  `ruby ~/.claude/pst/bin/change_config.rb doctor` against a `CHANGE.md` in
  progress to validate it before a full sweep.
- `boot.up` never returns: it must leave the app running in the background, not
  block. A foreground dev-server command has to self-detach (see the template's
  `boot.up` comment); a blocking command hangs the run before health is ever
  polled.
- The app never becomes healthy: exit 2 with the health url and the tail of the
  boot command's and the health poll's own output, so the real cause (a missing
  env var, a build failure, an unreachable proxy) is visible instead of hidden
  behind a bare timeout.
- A browser lane runs but browserless never becomes ready: the lane records a
  failing finding rather than crashing the whole run.
- Leftover `pst-change-*` containers or networks from a run that crashed before
  its teardown: `ruby ~/.claude/pst/bin/change_run.rb sweep` force-removes any
  not owned by the current run.
