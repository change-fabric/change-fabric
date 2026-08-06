# CHANGE.md frontmatter specification

Schema version: 0.6.0

Status: stable. This is the golden reference for authoring a repo's `CHANGE.md`
frontmatter. A maintainer or an AI agent creating a new repo's `CHANGE.md` reads
this to get every field right without reverse-engineering the parser. The field
set and version here are kept honest by `test/change_schema_spec_test.rb`, which
fails if this document and the parsing code (`scripts/change_schema.rb`) drift.

## What CHANGE.md is

`CHANGE.md` is a repo's answer to "how do changes get made here." It sits in the
same lineage as the emerging class of well-known, root-level project convention
files that a tool or a newcomer reads to operate correctly in a specific repo:

- `AGENTS.md` answers "how does a coding agent work in this repo."
- `CLAUDE.md` answers "what does Claude need to know to work here."
- `design.md` answers "how is this project designed."
- `CHANGE.md` answers "how do changes get made and promoted here."

Like those, it is a single conventionally-named root file, kept concise and
current, treated as a first-class part of the repo rather than an afterthought,
and written so a newcomer (human or agent) gets correct behavior from reading it.
It must also be self-contained: it must not cite or depend on another tool's own
internal conventions (a coding harness's config vocabulary, an unrelated
CLAUDE.md table), since change-fabric reads only this file.
Its substance is the concrete governance FAQ (promotion rules, self-review
policy, admin-bypass conditions) in the prose body, plus the two machine-readable
frontmatter blocks this spec covers.

## Structure

`CHANGE.md` opens with a single YAML frontmatter block fenced by `---`, carrying
two required top-level keys plus two optional ones, followed by the prose
governance FAQ:

```
---
spec_version: "0.6.0"   # optional: the schema version this file was authored against
change_config:
  ...        # mechanical target-app details the audit lanes read
change_policy:
  ...        # machine-checkable governance the merge gate enforces
contributors_team:
  ...        # optional: the team this repo belongs to, and where its artifacts publish
---

# Change management for <repo>
...prose FAQ...
```

There is no separate config file. A repo can carry only `CHANGE.md`, with none
of the audit tools installed as its own dependencies; the platform supplies each
runner as an ephemeral, digest-pinned container.

`reference/CHANGE.template.md` is a complete, copyable starting point. This spec
is the field-by-field authority behind it.

### spec_version (0.3.0): pinning a file to the schema it was authored against

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `spec_version` | string | no | The schema version (this document's "Schema version" line) `CHANGE.md` was authored against. Compared against the installed toolkit's `ChangeSchema::VERSION` at every config load; a mismatch never blocks a run, but surfaces a named warning (`doctor`, and at the top of a real sweep) rather than letting a field the installed toolkit does not understand yet (or no longer emits) fail silently. Omit it and nothing is checked. |

## Conventions in the field tables

Field paths are dotted. Placeholder segments are literal and mean:

- `<lane>`: any of the four lanes, `k6`, `a11y`, `zap`, `browserless`.
- `<branch>`: any git branch name (a promotion target such as `staging`).
- `<profile>`: any name under `change_config.profiles` (a deploy target such as `staging`).
- `<app>`: any name under `change_config.apps` (an app in a monorepo, 0.4.0).
- `[]`: a field on each item of a list.

Required means the platform cannot run without it. Almost everything is optional
with a sensible default; the one hard requirement is that at least one lane is
present and enabled.

## change_config fields

The mechanical block the audit lanes read. `boot` describes how to stand the app
up and confirm it is ready; `lanes` describes what to audit.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `change_config.project` | string | no (default `project`) | Label used in the Desktop report filename. |
| `change_config.boot.up` | string | no | Command that brings the app up, run from the repo root. Omit to assume the app is already running. Must return promptly and leave the app running in the background: a foreground command (`pnpm dev`) has to be self-detached (`nohup ... & echo $! >pidfile`, with `down` killing the recorded pid), since the run never proceeds past a command that blocks. |
| `change_config.boot.down` | string | no | Teardown command, always run after the sweep. `docker compose down` alone leaves named volumes intact across runs; add `-v` when the app's seed data is not fully idempotent, at the cost of a slower next boot. |
| `change_config.boot.network` | string | no | An existing docker network the runners join to reach app services by name. Omit to create an ephemeral network and reach the app via `host.docker.internal`. |
| `change_config.boot.target_url` | string | no | In-network base url the lanes default to (service-name form on a compose network). A per-lane `base_url` overrides it. |
| `change_config.boot.health.url` | string | no | Host-reachable url polled from the host (via curl, so a local-CA dev cert is trusted). Omit to skip the health wait. Prefer a published host port (created by the same `boot.up`) over a named host routed through a separately-running reverse proxy: the proxy is not part of this run's compose project, so a fresh ephemeral boot's container is never wired into it and the poll gets no response even though the app itself is healthy. |
| `change_config.boot.health.expect_status` | integer | no (default 200) | HTTP status that means healthy. |
| `change_config.boot.health.timeout_seconds` | integer | no (default 120) | How long to wait for health before failing the run. |
| `change_config.boot.env_file` | string or list of string | no | Repo-relative path(s) of env file(s) (simple `KEY=VALUE` lines, not shell `source`) parsed and merged into `boot.up`'s subprocess environment, later files winning over earlier ones and overriding the inherited environment for that subprocess. Lets a compose `build.args:` entry's `${VAR}` interpolation resolve (Compose reads `build.args` from the shell/`.env`, never from a service's own `env_file:`) without pre-exporting anything. A missing declared file fails the run by name. |
| `change_config.lanes.<lane>.enabled` | boolean | no (default true) | Whether this lane runs. Set false, or omit the lane, to skip it. |
| `change_config.lanes.<lane>.base_url` | string | no | Per-lane override of `boot.target_url`. |
| `change_config.lanes.<lane>.basic_auth.username_env` | string | no | Name of the environment variable holding the real HTTP Basic Auth username for a browser lane (`a11y`, `browserless`) hitting a target gated by it. The value is never written into `CHANGE.md`, the same rule `browserless.auth.email_env` already follows. Answered via `page.authenticate()`, never embedded in a url (see the 0.3.0 changelog entry for why). |
| `change_config.lanes.<lane>.basic_auth.password_env` | string | no | Name of the environment variable holding the real password paired with `basic_auth.username_env`. |
| `change_config.lanes.k6.script` | string | no | Repo-relative k6 script. Omit for the built-in light-load default. |
| `change_config.lanes.k6.env` | map | no | Environment variables passed to the k6 container (e.g. `BASE_URL`, `VUS`, `DURATION`). The built-in default script also reads `HEALTH_PATH` for the route it hits; when omitted here it defaults to `boot.health.url`'s own path, so the load test targets the same route the health check already proved reachable rather than an independently-guessed `/health`. |
| `change_config.lanes.k6.thresholds.http_req_failed` | string | no | k6 threshold expression applied to the built-in default script (e.g. `rate<0.01`). |
| `change_config.lanes.k6.thresholds.http_req_duration` | string | no | k6 threshold expression applied to the built-in default script (e.g. `p(95)<500`). |
| `change_config.lanes.k6.scenario.window` | string | no (default `per minute`) | The unit the expected peak is expressed in. |
| `change_config.lanes.k6.scenario.assumptions` | string | no | The pessimistic-in-its-favor assumptions behind the funnel, shown in the report narrative. |
| `change_config.lanes.k6.scenario.funnel[].stage` | string | no | Name of a funnel stage. |
| `change_config.lanes.k6.scenario.funnel[].value` | number | no | Absolute count at a stage (the funnel's starting volume). |
| `change_config.lanes.k6.scenario.funnel[].rate` | number | no | Multiplier applied to the running total at a stage (e.g. `0.25`). |
| `change_config.lanes.k6.scenario.expected_peak` | string | no | Explicit expected peak; derived from the funnel when omitted. |
| `change_config.lanes.k6.scenario.tested_to` | string | no | What the app was actually tested to, in prose. |
| `change_config.lanes.k6.scenario.tested_rate` | number | no | Tested sustained rate in the same unit as `window`; when present, the report computes the safety-margin multiple. |
| `change_config.lanes.k6.scenario.safety_margin` | string | no | A stated margin, used only when `tested_rate` is absent. |
| `change_config.lanes.k6.scenario.overload` | string | no | How the app behaves when deliberately pushed past its ceiling. |
| `change_config.lanes.k6.scenario.comparison` | string | no | One relatable comparison for the scale. |
| `change_config.lanes.a11y.routes` | list of string | no (default `/`) | Routes to scan with axe-core. |
| `change_config.lanes.a11y.threshold` | enum `minor` `moderate` `serious` `critical` | no (default `serious`) | Impact level at or above which a violation fails the lane. |
| `change_config.lanes.zap.targets` | list of string | no (default the lane base url) | URLs in scope for the ZAP baseline. An entry may be relative (`/`, `/admin`), resolved against the lane base url exactly as `a11y.routes` and `browserless.routes` already resolve, or absolute. Omitted, the lane scans the lane base url itself. Prefer relative when `profiles` exist: an absolute literal is a single global value no profile can override, so it points every profile at the same host regardless of which one is active. A scope spanning two genuinely distinct services needs absolute urls; restate them per profile under `profiles.<profile>.lanes.zap.targets` below. |
| `change_config.lanes.zap.strict` | boolean | no (default false) | When true, any low-risk-or-above alert fails; when false, only high-risk fails. |
| `change_config.lanes.zap.auth` | map or null | no | Reserved for authenticated scans; the baseline runs unauthenticated. |
| `change_config.lanes.browserless.routes` | list of string or mapping | no (default `/`) | Routes to load at each viewport. A plain string is an unauthenticated route with no visual check. A mapping adds `path`, and optionally `auth` and `figma` below. |
| `change_config.lanes.browserless.routes[].path` | string | yes, on a mapping route | The route path (or absolute url) to load. |
| `change_config.lanes.browserless.routes[].auth` | boolean | no (default false) | Whether this route requires the session logged in via `lanes.browserless.auth` before it is checked. A route marked `auth: true` with no working `auth:` block is skipped with a named failing finding, never checked unauthenticated. |
| `change_config.lanes.browserless.routes[].figma.file_key` | string | yes, to enable the visual check on this route | The Figma file key (from the file's url) holding the reference frame. |
| `change_config.lanes.browserless.routes[].figma.node_id` | string | yes, to enable the visual check on this route | The Figma node id of the reference frame, fetched via the real `GET /v1/images/:file_key?ids=:node_id` REST API. |
| `change_config.lanes.browserless.routes[].figma.viewport` | string | no (default the first configured viewport) | Which viewport's screenshot this reference is diffed against (a Figma frame is normally authored for one breakpoint). |
| `change_config.lanes.browserless.viewports[].name` | string | no | Viewport label (e.g. `mobile`). |
| `change_config.lanes.browserless.viewports[].width` | integer | no | Viewport width in pixels. |
| `change_config.lanes.browserless.viewports[].height` | integer | no | Viewport height in pixels. |
| `change_config.lanes.browserless.auth.login_url` | string | yes, to check any `auth: true` route (unless `auth.steps` is used instead) | Login page path (relative to the lane's base url) or absolute url. Shorthand for a single-form login; normalized internally into a one-step `auth.steps` list, so `auth.steps` and this shorthand are two ways to write the same thing, never both at once. |
| `change_config.lanes.browserless.auth.email_env` | string | yes, to check any `auth: true` route (shorthand form) | Name of the environment variable holding the real test login email/username. The value is never written into `CHANGE.md`. |
| `change_config.lanes.browserless.auth.password_env` | string | yes, to check any `auth: true` route (shorthand form) | Name of the environment variable holding the real test login password. The value is never written into `CHANGE.md`. |
| `change_config.lanes.browserless.auth.email_selector` | string | no (default `input[name="email"]`) | CSS selector for the email/username field (shorthand form). |
| `change_config.lanes.browserless.auth.password_selector` | string | no (default `input[type="password"]`) | CSS selector for the password field (shorthand form). |
| `change_config.lanes.browserless.auth.submit_selector` | string | no (default `button[type="submit"]`) | CSS selector for the login form's submit control (shorthand form). |
| `change_config.lanes.browserless.auth.wait_for_selector` | string | no | An optional selector to wait for after submit, confirming the post-login page rendered before any auth-required route is checked (shorthand form). |
| `change_config.lanes.browserless.auth.timeout_ms` | integer | no (default 15000) | Timeout for each login step (navigation, field wait, post-login wait) (shorthand form). |
| `change_config.lanes.browserless.auth.steps[].url` | string | yes, on the first step | Page to navigate to before filling this step's fields (relative to the lane's base url, or absolute). Only the first step normally needs one; later steps continue on whatever page the previous step's submit landed on (a second form rendered in place, e.g. an OTP prompt). |
| `change_config.lanes.browserless.auth.steps[].fields[].selector` | string | yes | CSS selector for this step's input field. |
| `change_config.lanes.browserless.auth.steps[].fields[].env` | string | yes, unless `code_source` is set | Name of the environment variable holding this field's value (a password, a test-mode static code). Never written into `CHANGE.md`. Mutually exclusive with `code_source`. |
| `change_config.lanes.browserless.auth.steps[].fields[].code_source.url` | string | yes, to use `code_source` | An HTTP endpoint reachable from the browserless container on the run network (e.g. a Mailpit/MailHog dev inbox API) polled for this field's value. Resolved live, inside the browserless container, at fill time: never read, stored, or logged on the host, since a real OTP is inherently one-time and out-of-band. |
| `change_config.lanes.browserless.auth.steps[].fields[].code_source.pattern` | string | no | A regex applied to the endpoint's response body; the first capture group (or the whole match) becomes the field value. Omit to use the trimmed response body verbatim. |
| `change_config.lanes.browserless.auth.steps[].fields[].code_source.timeout_ms` | integer | no (default 20000) | How long to keep polling the endpoint for a match before failing this login attempt. |
| `change_config.lanes.browserless.auth.steps[].fields[].code_source.poll_interval_ms` | integer | no (default 1000) | Delay between polling attempts. |
| `change_config.lanes.browserless.auth.steps[].submit_selector` | string | no (default `button[type="submit"]`) | CSS selector for this step's submit control. |
| `change_config.lanes.browserless.auth.steps[].wait_for_selector` | string | no | An optional selector to wait for after this step's submit, confirming the next page (or the next step's form) rendered before continuing. |
| `change_config.lanes.browserless.auth.steps[].timeout_ms` | integer | no (default 15000) | Timeout for this step's navigation, field waits, and post-submit wait. |
| `change_config.lanes.browserless.figma.token_env` | string | no (default `FIGMA_ACCESS_TOKEN`) | Name of the environment variable holding a real Figma personal access token. |
| `change_config.lanes.browserless.figma.max_diff_percent` | number | no (default 10) | Pixel-diff percentage above which a route's Figma alignment check fails; a nonzero diff at or below this still reports as a warn so a rerun after a fix shows the number moving toward zero. |

### change_config.profiles (0.2.0): multiple deploy targets, one audit shape

A repo with more than one deployable target (a local Docker stack, a real
staging deployment, a real production deployment) declares each as a named
profile under `change_config.profiles` instead of a second, parallel
`CHANGE.<env>.md` file. A profile deep-merges its own values over the base
`change_config` above; anything it does not set is inherited unchanged. This
keeps one documented audit surface (the same lane routes, thresholds, and
viewports) across every environment, and lets a profile state only what
actually differs: how to reach that target and which lane base URLs point at
it. `ruby ~/.claude/cf/bin/change_run.rb all --profile staging` runs the
`staging` profile; omitting `--profile` uses `change_config.default_profile`
when set, or the bare `change_config` fields when there is no `profiles` block
at all. A `profiles` block with no `--profile` flag and no `default_profile`
is a setup error, not a silent default, since running the wrong environment's
audit against the wrong target is worse than refusing to guess.

A profile may set only `project`, `boot.*`, and a lane's `enabled`/`base_url`/
`basic_auth`; setting anything else (a lane's `routes`, `thresholds`,
`viewports`, or any other lane field) is rejected. This is the deliberate
scope limit that keeps `profiles.<profile>.*` a small, fully documented
mirror of the base config's own mechanical fields rather than a second copy
of the whole schema: a profile changes *where* the same audit runs, never
*what* it audits. `zap.targets` (0.4.0) is the one exception a profile may
also set, and it is consistent with the rule rather than a break from it: a
target list is a *where*, not a *what*, the same reason `base_url` is
already overridable.

**Adopting profiles without breaking the bare merge gate.** The moment a
`profiles` block is non-empty, a bare `change_run.rb all` (the invocation
`cf:drive`'s local-stack lane and the merge hook's own gate both run) has no
profile to resolve and raises, per the setup-error rule above. Give it one:
add an empty (or near-empty) profile for whatever the bare config already is
(conventionally named `local`) and set `default_profile: local`. A bare run
then resolves to `local`, which changes nothing about what it audits since
its overrides are empty; only naming it makes it addressable. See the
worked example below.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `change_config.default_profile` | string | no | The profile `--profile` falls back to when omitted. Required (as an explicit `--profile` flag, if not set here) whenever `profiles` is non-empty. |
| `change_config.profiles.<profile>.project` | string | no | Overrides `change_config.project` for this profile. |
| `change_config.profiles.<profile>.boot.up` | string | no | Overrides `change_config.boot.up`. A real, already-running deployment (staging, production) typically sets this to `"true"`, a no-op, since there is nothing to boot; the `health` check below is what actually confirms the target is reachable. |
| `change_config.profiles.<profile>.boot.down` | string | no | Overrides `change_config.boot.down`. |
| `change_config.profiles.<profile>.boot.network` | string | no | Overrides `change_config.boot.network`. |
| `change_config.profiles.<profile>.boot.target_url` | string | no | Overrides `change_config.boot.target_url`. |
| `change_config.profiles.<profile>.boot.health.url` | string | no | Overrides `change_config.boot.health.url`. |
| `change_config.profiles.<profile>.boot.health.expect_status` | integer | no | Overrides `change_config.boot.health.expect_status`. |
| `change_config.profiles.<profile>.boot.health.timeout_seconds` | integer | no | Overrides `change_config.boot.health.timeout_seconds`. |
| `change_config.profiles.<profile>.boot.env_file` | string or list of string | no | Overrides `change_config.boot.env_file`. |
| `change_config.profiles.<profile>.lanes.<lane>.enabled` | boolean | no | Overrides whether `<lane>` runs under this profile (e.g. skip `zap` locally, require it in staging). |
| `change_config.profiles.<profile>.lanes.<lane>.base_url` | string | no | Overrides `<lane>`'s base URL for this profile. The lane's other fields (`routes`, `thresholds`, `viewports`, ...) are always inherited from the base `change_config.lanes.<lane>` block; a profile cannot set them. |
| `change_config.profiles.<profile>.lanes.<lane>.basic_auth.username_env` | string | no | (0.3.0) Overrides `<lane>`'s Basic Auth username env var name for this profile, e.g. when staging sits behind a Basic Auth wall but local dev does not. |
| `change_config.profiles.<profile>.lanes.<lane>.basic_auth.password_env` | string | no | (0.3.0) Overrides `<lane>`'s Basic Auth password env var name for this profile. |
| `change_config.profiles.<profile>.lanes.zap.targets` | list of string | no | (0.4.0) Overrides the ZAP scope for this profile. The one lane field other than `enabled`/`base_url`/`basic_auth` a profile may set, for a scope spanning two genuinely distinct services that a relative-path `targets` entry cannot express. Rejected on every other lane; only zap reads it. |

### change_config.apps (0.4.0): multiple apps, one governance policy

`change_config.profiles` covers one app with several deploy targets: it
changes *where* the same audit runs, never *what* it audits, and rejects a
profile lane override that tries to set anything else. That limit is
deliberate and stays in force. It is also exactly why a second, genuinely
different app in the same repo (a multi-route authenticated Next.js portal
and a single-route unauthenticated static site) cannot be expressed as a
profile: they differ in *what* is audited, not in *where*.

`change_config.apps` is the missing axis: one repo, several apps, one
governance policy. `change_policy` stays repo-wide, unchanged; only
`change_config` becomes a registry when a repo has more than one app to sweep.

```
CHANGE.md                  repo-wide: change_policy + a registry of apps + prose FAQ
apps/<x>/CHANGE.app.yml    one app's change_config (boot + lanes + its own profiles)
```

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `change_config.apps.<app>.config` | string | yes, on each entry | Repo-relative path to that app's config file (conventionally `<app-dir>/CHANGE.app.yml`). The file's only accepted top-level key is `change_config:`; a `change_policy:` block there is rejected at load, since governance is repo-wide and lives only in the root `CHANGE.md`. An app file's `change_config:` accepts every field in the tables above except `change_config.apps.*` itself (no nesting: a flat, one-level registry). |
| `change_config.apps.<app>.path` | string | no (default the config file's directory) | Repo-relative directory this app owns. Reported by `doctor`. Does **not** affect path resolution: an app config's repo-relative paths (a k6 `script`) and its `boot` commands always resolve against the repo root, the directory holding the root `CHANGE.md`, never the app file's own directory. |
| `change_config.apps.<app>.description` | string | no | One line naming what this app is, surfaced by `doctor` and in the sweep roll-up report. |
| `change_config.apps.<app>.enabled` | boolean | no (default true) | Whether this app participates in a bare sweep and in the default merge-gate requirement. `false` parks an app (a work-in-progress config) without deleting its registration or silently shrinking the gate. |

**No `apps:` key means nothing changes.** A `CHANGE.md` with no
`change_config.apps` parses, runs, reports, and gates exactly as it did
before this section existed: single-app mode is a registry of exactly one
entry, the root file itself.

**The root cannot be both registry and app.** Once `change_config.apps` is
present, the root `change_config` may not also declare its own
`boot`/`lanes`/`profiles`/`default_profile`; that combination is a load
error naming both keys. A root that is simultaneously a registry and an app
makes `--app` meaningless for that one app and makes
`change_policy.promotion.<branch>.profile` ambiguous about whose profile is
meant. Adopting the monorepo shape is a verbatim cut-and-paste of the
existing block into one app file, for example `apps/<name>/CHANGE.app.yml`.

**Shared-compose monorepo trap.** In a monorepo where several apps are
services of one shared `docker-compose.yml`, a naive `boot.down: docker
compose down` in one app's config tears down every sibling app's containers
too. State the rule in each app's `boot`: an app's `boot.up` should be an
idempotent "already running?" guard (e.g. `docker compose ps <service>
--status running --format '{{.Names}}' | grep -q <container>`) and its
`boot.down` should be `"true"`, with the stack's actual lifecycle owned
outside the sweep.

**Invocations:**

```
change_run.rb all                              # sweep every enabled app
change_run.rb all --app scattergram             # one app
change_run.rb all --app portal --app scattergram
change_run.rb all --profile staging             # every app, each against its own staging target
change_run.rb a11y --app scattergram            # one lane, one app
change_config.rb doctor                         # validates the root registry and every app file
```

A bare `change_run.rb all` sweeps every registered, enabled app, in registry
order, and passes only if all of them pass: this preserves what a bare
comprehensive run has always meant to the merge gate, "this repo is
releasable," rather than "one arbitrary app is." `--app NAME` (repeatable)
narrows the sweep; an unknown name is a setup error listing the registered
apps. `--profile` composes with `--app` exactly as it always has, a per-app
deploy-target selector resolved independently for each app in the sweep: an
app with no `profiles:` block ignores `--profile` entirely, and an app whose
`profiles:` block does not define the requested name is a setup error named
per app.

**Not a diff-derived set, on purpose.** The required app set for a merge
gate (`change_policy.promotion.<branch>.apps`, or every registered enabled
app when omitted) is never computed from which files a PR touched. The merge
guard is a fail-open advisory hook by design: any check it cannot determine
fails open rather than blocking a merge on a false positive. Computing an
"affected apps" set needs a trustworthy merge-base diff and a path-to-app
mapping, either of which can be indeterminate, and an indeterminate case
would fail open and silently shrink the required set. A gate whose
strictness depends on a diff computation that can fail open is not a gate.
State which apps a branch actually requires as a reviewable governance
decision in the file a human reads, not as a side effect of a diff.

**Example: a two-app monorepo.**

```yaml
---
spec_version: "0.4.0"
change_config:
  project: my-repo
  apps:
    portal:
      config: apps/portal/CHANGE.app.yml
      path: apps/portal
      description: Authenticated multi-route app
    marketing:
      config: apps/marketing/CHANGE.app.yml
      path: apps/marketing
      description: Static, unauthenticated single-route site
change_policy:
  promotion:
    staging:
      require_change_pass: true
      apps: [portal]           # optional; omit to require every registered app
    production:
      require_change_pass: true
---

# Change management for my-repo
...prose FAQ, with a per-app section...
```

```yaml
# apps/portal/CHANGE.app.yml
# change_policy: is rejected here; governance is repo-wide, in the root
# CHANGE.md. Repo-relative paths and boot commands below resolve against the
# repo root, not this file's directory.
change_config:
  project: my-repo-portal
  boot:
    up: docker compose ps portal --status running --format '{{.Names}}' | grep -q my-repo-portal
    down: "true"
    target_url: http://my-repo-portal:3000
    health: { url: http://localhost:3000/health }
  lanes:
    a11y: { routes: ["/login", "/dashboard"] }
```

## change_policy fields

The machine-checkable block the merge gate (`change_merge_guard.rb`) reads. The
prose body is the source of truth a human reads; this block states the same
rules in a form the gate can enforce, and the body is expected to explain it.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `change_policy.protected_branches` | list of string | no (default `[staging, production]`) | Branches whose merges are gated. The union of this list and every branch under `promotion`. |
| `change_policy.gate.require_change_pass` | boolean | no (default true) | Fallback gate for a protected branch that has no `promotion` rule of its own. |
| `change_policy.promotion.<branch>.review_required` | boolean | no | Whether a merge review is required to promote into this branch (read by humans; explained in prose). |
| `change_policy.promotion.<branch>.self_review_allowed` | boolean | no | Whether the author may review or merge their own change (read by humans; explained in prose). |
| `change_policy.promotion.<branch>.require_change_pass` | boolean | no (default true) | Gates a merge into this branch on a passing comprehensive cf:change run for the head SHA. |
| `change_policy.promotion.<branch>.ci_gate` | string | no | The CI that must be green to promote (read by humans; explained in prose). |
| `change_policy.promotion.<branch>.ci_skippable` | boolean | no | Whether that CI gate can be skipped, and the prose says by whom. |
| `change_policy.promotion.<branch>.profile` | string | no | (0.2.0) Scopes `require_change_pass` to one named `change_config.profiles` entry's own recorded pass, instead of any profile-less comprehensive run. A passing `staging` profile run never satisfies a branch whose rule names `production`. |
| `change_policy.promotion.<branch>.apps` | list of string | no (default every registered enabled app) | (0.4.0) Restricts which `change_config.apps` entries' comprehensive passes gate a merge into this branch. Names must exist in `change_config.apps`. Meaningless (and ignored) outside monorepo mode. An explicitly empty list is reported as a setup error by `doctor` rather than silently gating nothing; use `require_change_pass: false` to gate on nothing. |
| `change_policy.admin_bypass.allowed` | boolean | no (default false) | Whether admin-bypass merging (`gh pr merge --admin`) is permitted at all for a protected branch. |
| `change_policy.admin_bypass.require_change_pass` | boolean | no (default true) | Whether an allowed admin bypass still requires the cf:change gate to have passed. |
| `change_policy.admin_bypass.conditions` | string | no | The repo's stated condition for an acceptable admin bypass, surfaced in the gate's deny reason. |

## contributors_team fields (0.6.0)

The optional third block. It registers the repo with a contributors team (the
`team_id`, the team's public signing key, and the roster of who is on it) and,
under `platform`, with the hosted artifacts service that team publishes its
findings runs to.

`platform` is the switch for the whole artifact pipeline. With it present, a
completed sweep also builds a self-contained HTML findings artifact carrying the
run's contributor and git context, every lane's findings, the screenshots and
per-viewport recordings the browserless lane captured, and one annotated PDF per
viewport, then publishes that bundle to the artifacts service. Without it, none
of that happens and the sweep behaves exactly as it did in 0.4.0: no media is
captured, no bundle is built, nothing is published.

**Publishing is three HTTP calls and no cloud credential.** The client declares
the run and its files (`POST /v1/artifacts`), receives one presigned upload URL
per file, sends the bytes straight to storage, and says it finished
(`POST /v1/artifacts/:id/complete`). It authenticates with a team API key and
nothing else: no AWS profile, no SDK, no bucket name, no distribution. The
service assigns the key prefix, records the run, lists it on the team's findings
page in the web app, and decides who may open it (a signed-cookie round trip for
a person's browser, a presigned download for a machine). None of those facts
appear in this block because none of them are the repo's to state.

**Nothing under `platform` is a credential.** `api_key_env` names the
environment variable a team API key arrives in, never the key; `basic_auth`
names the environment variables holding the deployment-wide fence in front of
the API, never their values. This is the same indirection
`lanes.<lane>.basic_auth.username_env` already uses. A contributor stores their
own key once with `ruby scripts/cf_team_join.rb --platform <organization>
<team> --stdin`, which caches it in the macOS Keychain under service
`change-fabric-platform`, account `<organization>/<team>`; the publisher reads
the named env var first and falls back to that entry, so on a developer machine
the key is in neither the repo nor the shell.

See `scripts/CF_TEAM_SETUP.md` for the runbook.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `contributors_team.team_id` | string | yes, to register a team | Stable id of the contributors team this repo belongs to, minted by `cf_team_init.rb`. Distinct from `contributors_team.platform.team_id`, which is the hosted service's own id for the team. |
| `contributors_team.public_key_ed25519` | string | no | Base64 of the team's Ed25519 public (verify-only) key. Safe to commit; the private half lives in a shared 1Password vault and, per machine, in the Keychain. |
| `contributors_team.contributors[].id` | string | yes, on each entry | Stable contributor id. A machine claims one via `cf_team_join.rb`; an id not in this list resolves to no identity at all. |
| `contributors_team.contributors[].name` | string | yes, on each entry | Display name, shown as the run's author on published artifacts and on the team's findings page. |
| `contributors_team.organization` | string | yes, to publish | (0.6.0) The organization slug on the hosted platform. Together with `team` it is half of what a run is addressed by and the Keychain account the team API key is stored under. |
| `contributors_team.team` | string | yes, to publish | (0.6.0) The team slug on the hosted platform. Its presence, with `organization`, is what enables the pipeline; either one empty or absent is treated as "not configured". |
| `contributors_team.platform.enabled` | boolean | no (default true) | (0.6.0) Set false to keep the block committed but publish nothing, for example while a team is being moved between organizations. |
| `contributors_team.platform.api_url` | string | no (default `https://api.staging.changefabric.org`) | (0.6.0) Origin of the platform API this repo publishes through, with no trailing slash. A field rather than a constant because a production estate is a different origin, not a different build of the client. |
| `contributors_team.platform.api_key_env` | string | no (default `CF_TEAM_API_KEY`) | (0.6.0) Name of the environment variable holding this team's API key. Named, never valued. A machine publishing for two teams gives each its own variable; one team on one machine needs no entry at all. |
| `contributors_team.platform.team_id` | string | no | (0.6.0) The service's own id for this team. Usually omitted: the API key is already scoped to exactly one team, so the publisher asks `GET /v1/whoami-key` which team that is rather than committing an id the repo cannot verify. Setting it saves that one round trip. |
| `contributors_team.platform.basic_auth.username_env` | string | no | (0.6.0) Name of the environment variable holding the username half of the deployment-wide HTTP Basic Auth fence in front of the API. A property of the deployment, not of the team: an environment without such a fence omits the block. |
| `contributors_team.platform.basic_auth.password_env` | string | no | (0.6.0) Name of the environment variable holding the password half of that same fence. |
| `contributors_team.platform.media.screenshots` | boolean | no (default true) | (0.6.0) Whether the browserless lane captures a full-page screenshot per route and viewport for the artifact. |
| `contributors_team.platform.media.video` | boolean | no (default true) | (0.6.0) Whether the browserless lane records one video per viewport covering that viewport's whole route walk. |
| `contributors_team.platform.media.video_fps` | integer | no (default 6) | (0.6.0) Frame rate of that recording. Higher is smoother and proportionally larger; the recording travels base64 inside the lane's single browserless response, so this is the main lever on that payload. |

```yaml
contributors_team:
  team_id: acme-web
  public_key_ed25519: 3BXo6b9PO7gy35dZT1i7Znsaky4sOPn9b6V5JwdnW+4=
  contributors:
    - { id: pat, name: Pat Taylor }
  organization: acme
  team: web
  platform:
    api_url: https://api.staging.changefabric.org
    api_key_env: CF_TEAM_API_KEY
    basic_auth:
      username_env: CF_PLATFORM_BASIC_AUTH_USER
      password_env: CF_PLATFORM_BASIC_AUTH_PASSWORD
```

### The legacy identity fields and the platform fields run in parallel

`team_id`, `public_key_ed25519` and `contributors` are **not deprecated and have
no removal version.** They are the registration `cf_team_init.rb` mints, and
they are what the presence and secret-alert capabilities actually read:
`scripts/contributors_team.rb` resolves this machine's identity from them,
`telemetry/infra`'s Lambdas verify signatures against the public key, and the
`cf-teams` DynamoDB table is keyed on `team_id`. None of that goes through the
hosted platform, and nothing about adopting `organization`, `team` and
`platform:` changes it.

So a migrated repo carries **both**, permanently, and they answer different
questions:

| Fields | Answer | Read by |
| --- | --- | --- |
| `team_id`, `public_key_ed25519`, `contributors` | who this repo's contributors are, and how their hooks sign | presence, secret-alerts, `cf-teams` |
| `organization`, `team`, `platform:` | where this repo's findings artifacts are published | `cf:change`'s artifact step |

The one thing 0.6.0 deprecated is `contributors_team.artifacts`, the per-team
S3 bucket that predates the hosted service, and only that. It is removed at
0.7.0. Nothing else in this block is slated for removal.

`platform.team_id` and the top-level `team_id` are deliberately different
values and are not interchangeable: one is the hosted service's own id for the
team, the other is the id the team had before the service existed. The link
between them is recorded server-side as the team's `legacyTeamId`, not by making
one field mean both.

### Migrating a registered team onto the platform

`ruby scripts/cf_team_migrate.rb --org <slug> --email <you> [--team <slug>]`
carries an existing registration onto the hosted platform in one run. Against
the repo it is pointed at (the current directory by default) it reads the
`contributors_team:` block and then resolves or creates:

- an **organization** for the team,
- a **team** carrying the old `team_id` as its `legacyTeamId` and the old
  `public_key_ed25519` as its `publicKeyEd25519`, so the hosted team is
  provably the same team,
- your own **team membership**, because the viewer cookies that open a
  published artifact are minted against team membership and not against an
  organization role,
- one **contributor alias** per `contributors[]` entry, mapping the roster id
  and display name so runs published under the old id still read as somebody,
- a **repo link** for this repo's normalized `repo_id`,
- a **team API key**.

It then PRINTS the replacement block and the `cf_team_join.rb --platform`
command to store the key. It never edits `CHANGE.md`: the change is additive
and belongs in a reviewed commit like any other.

`--dry-run` reports what it would do and writes nothing at all, including not
creating an account. Re-running without it is idempotent: the organization,
team, membership, aliases and repo link are found and reused rather than
duplicated. A team API key is the one exception, and unavoidably so, because a
key is returned by exactly one response and cannot be handed back afterwards;
each real run mints another, and the old ones stay listed and revocable on the
team's page.

See `scripts/CF_TEAM_SETUP.md` for the runbook.

### contributors_team.artifacts (0.5.0): deprecated, removed at 0.7.0

Before the hosted service existed, a team provisioned its own private S3 bucket
behind its own CloudFront distribution with its own HTTP Basic Auth credential,
and the client uploaded to it directly with the AWS SDKs. That is what
`contributors_team.artifacts` describes.

It is **deprecated at 0.6.0 and will be removed at 0.7.0.** The fields below
still parse, so a repo that has not migrated still resolves a configuration and
still builds its bundle on the Desktop, and `platform:` wins whenever both
blocks are present. But the publisher no longer carries an AWS SDK or an AWS
credential of any kind, so a repo on the legacy block publishes nothing and is
told so as a named warning on the run. Migrating is replacing the block with
`organization`, `team`, and `platform:` above.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `contributors_team.artifacts.enabled` | boolean | no (default true) | Deprecated. Set false to keep the block committed but publish nothing. |
| `contributors_team.artifacts.bucket` | string | yes, on the legacy block | Deprecated. The team's private artifact bucket. Its presence is what made the legacy path resolve. |
| `contributors_team.artifacts.region` | string | no (default `us-east-1`) | Deprecated. Region of the bucket and the manifest table. |
| `contributors_team.artifacts.aws_profile` | string | no (default `personal`) | Deprecated. Local AWS profile the legacy uploader authenticated with. |
| `contributors_team.artifacts.distribution_id` | string | no | Deprecated. CloudFront distribution id, used only to invalidate the rewritten index objects. |
| `contributors_team.artifacts.domain` | string | no | Deprecated. The distribution's domain, the only source of a viewer url on the legacy path. |
| `contributors_team.artifacts.manifest_table` | string | no (default `cf-change-artifacts`) | Deprecated. DynamoDB table holding one row per published run, which the legacy team index page was rebuilt from. The service's own database replaces it. |
| `contributors_team.artifacts.basic_auth.username` | string | no (default `cf`) | Deprecated. Username half of the per-team viewer credential the legacy CloudFront function checked. |
| `contributors_team.artifacts.basic_auth.ssm_parameter` | string | no | Deprecated. Name of the SSM SecureString parameter holding `username:password` for that credential. |
| `contributors_team.artifacts.basic_auth.secret_ref` | string | no | Deprecated. A 1Password `op://` reference for the same credential. |
| `contributors_team.artifacts.media.screenshots` | boolean | no (default true) | Deprecated. Superseded by `contributors_team.platform.media.screenshots`. |
| `contributors_team.artifacts.media.video` | boolean | no (default true) | Deprecated. Superseded by `contributors_team.platform.media.video`. |
| `contributors_team.artifacts.media.video_fps` | integer | no (default 6) | Deprecated. Superseded by `contributors_team.platform.media.video_fps`. |

## Worked examples

### Minimal

The smallest useful `CHANGE.md`: one enabled lane, default policy.

```
---
change_config:
  project: my-app
  boot:
    up: docker compose up -d --build app
    down: docker compose down
    target_url: http://app:3000
    health:
      url: http://localhost:3000/health
  lanes:
    a11y:
      routes: ["/login", "/home"]
change_policy:
  promotion:
    production:
      require_change_pass: true
---

# Change management for my-app

...prose FAQ...
```

### Admin-bypass allowed, gated

A repo that admin-merges routinely once CI is green, with the audit gate still
applied.

```
change_policy:
  promotion:
    staging: { require_change_pass: true }
    production: { require_change_pass: true }
  admin_bypass:
    allowed: true
    require_change_pass: true
    conditions: "CI green on the head commit; the tech lead may bypass-merge own work when no separate reviewer is available"
```

### Multiple deploy targets (profiles)

Three real targets sharing the same lane definitions: a local Docker stack,
a real staging deployment (behind a Basic Auth wall), and a real production
deployment. `local` is an empty profile naming the base config itself, per
the adoption-recipe note above, so `default_profile: local` makes a bare run
resolve to something instead of raising. Staging and production both
no-op `boot.up`/`boot.down` since there is nothing to boot, and point the
same `k6` lane at their own already-running host. `production`'s promotion
rule requires the `production` profile's own pass, not staging's.

```
change_config:
  project: my-app
  default_profile: local
  boot:
    up: docker compose up -d --build app
    down: docker compose down
    target_url: http://app:3000
    health:
      url: http://localhost:3000/health
  lanes:
    k6:
      env: { BASE_URL: http://app:3000 }
  profiles:
    local: {}
    staging:
      project: my-app-staging
      boot:
        up: "true"
        down: "true"
        target_url: https://staging.my-app.example
        health: { url: https://staging.my-app.example/health }
      lanes:
        k6: { base_url: https://staging.my-app.example }
        a11y: { basic_auth: { username_env: STAGING_BASIC_AUTH_USER, password_env: STAGING_BASIC_AUTH_PASSWORD } }
    production:
      project: my-app-production
      boot:
        up: "true"
        down: "true"
        target_url: https://my-app.example
        health: { url: https://my-app.example/health }
      lanes:
        k6: { base_url: https://my-app.example }
change_policy:
  promotion:
    staging: { require_change_pass: true, profile: staging }
    production: { require_change_pass: true, profile: production }
```

`ruby ~/.claude/cf/bin/change_run.rb all --profile staging` runs the
`staging` profile; a bare `change_run.rb all` resolves `default_profile:
local`, which changes nothing (`local: {}` has no overrides) but is what
makes the bare invocation resolve at all instead of raising the
no-profile-selected setup error.

`basic_auth.username_env`/`password_env` above name environment variables,
not values: the real credentials live wherever your own secrets flow
already puts them (a `boot.env_file`, a CI secret, a local shell export),
the same indirection `browserless.auth.email_env`/`password_env` already
uses for form-based logins. Nothing under `basic_auth` is ever a real
credential written into `CHANGE.md`.

For a full example of every field, see `reference/CHANGE.template.md`.

## Versioning and changelog

The schema carries its own semantic version (`ChangeSchema::VERSION` in
`scripts/change_schema.rb`, mirrored by the "Schema version" line at the top of
this document). It is independent of the cf skills toolkit's own version, which
is carried by that repo's `skills/v*` release tags rather than by any file in
the tree. Adding, removing, or renaming a frontmatter field
is a schema change: bump this version, update `scripts/change_schema.rb`, and
record the change below in the same pass. The drift test fails if the field set
or the version here and in the code disagree, so a schema change cannot land
half-done.

Version scheme (semver for the schema):

- Major: a breaking change (a field removed or renamed, a required field added,
  a type or meaning change that invalidates existing files).
- Minor: a backward-compatible addition (a new optional field).
- Patch: a documentation-only clarification with no field-set change.

Pre-release identifiers (SemVer 2.0.0): while a target version is being
floated before it is final, it carries a `-alpha.N` or `-beta.N` suffix, e.g.
`0.4.0-alpha.1`, `0.4.0-alpha.2`, `0.4.0-beta.1`, then the clean `0.4.0`. A
pre-release orders before its release (`0.4.0-alpha.1` precedes `0.4.0`),
which is exactly the "not final yet" meaning wanted; a bare letter suffix
like `0.4.0a` was considered and rejected, since it is not valid SemVer, is
ambiguous about direction (reads equally like a patch *after* `0.4.0`), and
buys nothing a real prerelease identifier doesn't already give for free. The
suffix is URL-safe as a `/spec/<version>` path segment and a
`spec/v<version>` git tag suffix without escaping, since hyphen and
dot are unreserved in both.

The field set may still change between pre-releases: a field added in
`0.4.0-alpha.1` may be removed again in `0.4.0-alpha.2` before `0.4.0` ships.
The drift test still requires this document and `scripts/change_schema.rb`
to agree exactly at every pre-release step; the suffix only marks that the
target isn't final, it never relaxes doc/code agreement. The Major/Minor/
Patch classification above is decided against the last *stable* release and
fixed once the target number is chosen; the pre-release suffix is orthogonal
to it. The changelog below records shipped (stable) versions only: a
pre-release's intermediate churn earns no permanent entry, and a version's
eventual changelog entry describes its net field-set delta relative to the
prior stable release, not each alpha/beta iteration along the way.

Pre-release schema versions are not deployed to the public
`changefabric.org` site; iterate on a branch (tagging each floated
pre-release you actually want a consumer to be able to pin, same
`spec/v<version>` convention) and only merge the stable version to
`main`, which is what the site and its `/spec` index track.

A stable version is released by pushing `spec/v<version>` from `main`, which
publishes a GitHub Release carrying that version's `CHANGELOG.md` section and
this document as an asset. Merging to `main` releases nothing on its own, and
the live site is deployed separately by its own tag. The full model, including
why the earlier `change-schema/v<version>` prefix was retired, is the repo's
root `RELEASING.md`.

### Changelog

- 0.1.0: initial pre-release specification, dogfooded end to end against real
  consumer repos before its first tagged release. Consolidates the mechanical
  config (formerly a separate `.cf/change.yml`) and the governance policy
  into the single `CHANGE.md` frontmatter, with `change_config:` and
  `change_policy:` blocks. Includes, from that dogfooding: authenticated
  browserless checks and Figma visual alignment (`routes[]` as a mapping with
  `path`/`auth`/`figma`, a lane-level `auth:` login flow, a `figma:` pixel-diff
  block); `boot.env_file` to source a compose `build.args:` entry's `${VAR}`
  interpolation into `boot.up`'s subprocess environment; and
  `lanes.browserless.auth.steps[]`, a multi-step login (each step with its own
  `url`, `fields[]`, `submit_selector`, `wait_for_selector`, `timeout_ms`),
  covering a login needing more than one form (an OTP flow: submit an email,
  then a code from a second form), a field's value resolved from `env` or a
  `code_source` that polls an HTTP endpoint live rather than ever reading,
  storing, or logging the code on the host.
- 0.2.0: `change_config.profiles`, named deploy-target overrides (a local
  Docker stack, a real staging or production deployment) sharing one audit
  surface instead of a separate `CHANGE.<env>.md` per environment. A profile
  may set `project`, `boot.*`, and a lane's `enabled`/`base_url`, deep-merged
  over the base `change_config`; `default_profile` and `change_run.rb
  --profile NAME` select one. `change_policy.promotion.<branch>.profile`
  scopes that branch's gate to one named profile's own recorded pass, so a
  passing `staging` run never satisfies a `production` promotion gate.
- 0.3.0: `change_config.lanes.<lane>.basic_auth.username_env`/`.password_env`
  (and the matching profile override) for a browser lane (`a11y`,
  `browserless`) hitting a target gated by HTTP Basic Auth. Names of
  environment variables, never real values, the same indirection
  `browserless.auth.email_env`/`password_env` already uses. Answered via
  Puppeteer's `page.authenticate()`, never by embedding credentials in the
  url: a `https://user:pass@host` url loads fine, but the Fetch spec forbids
  constructing a `Request` from a url carrying credentials, so any
  same-origin `fetch()` the loaded page's own JS makes (a framework's Server
  Action, an RSC navigation) throws and crashes the page. Setting `basic_auth`
  on a non-browser lane (`k6`, `zap`), at the base config or in a profile
  override, is rejected at load: neither lane reads it, so silently accepting
  it would be a credential the config author believes is doing something.
  Also adds top-level `spec_version`, compared against the installed
  toolkit's `ChangeSchema::VERSION` at every config load; a mismatch never
  blocks a run but surfaces a named warning (`doctor`, and the top of a real
  sweep) instead of a field silently not doing what the file's author
  expected.
- 0.3.1: documentation-only, no field-set change. Adds the pre-release
  identifier convention above (`-alpha.N`/`-beta.N`, SemVer 2.0.0), and notes
  in `spec_version_mismatch`'s warning when either side of a mismatch is a
  pre-release schema, since that class of skew (a field set still actively
  changing) is different from a skew between two stable releases.
- 0.4.0: `change_config.apps`, a registry of the several genuinely different
  apps one monorepo contains, each with its own config file (conventionally
  `<app-dir>/CHANGE.app.yml`) carrying its own `boot`/`lanes`/`profiles`. This
  is the axis `profiles` (0.2.0) deliberately does not cover: a profile
  changes *where* one audit runs, never *what* it audits, so a second app
  with different routes, a different boot, and no auth at all cannot be
  expressed as a profile. An app file's only accepted top-level key is
  `change_config:`; `change_policy:` stays repo-wide in the root `CHANGE.md`,
  since duplicating governance per app is the drift this design exists to
  prevent. Repo-relative paths and boot commands in an app file resolve
  against the repo root, not the app's own directory. A bare `change_run.rb
  all` sweeps every registered enabled app and passes only if all of them
  pass; `--app NAME` (repeatable) narrows it and composes with `--profile`,
  which stays a per-app deploy-target selector. The gate record for a head
  SHA now carries a per-app map and merges across separate `--app` runs
  instead of overwriting, with the pre-existing top-level `scope`/`status`
  retained as the aggregate. `change_policy.promotion.<branch>.apps`
  restricts which apps' passes gate a branch; omitted, every registered
  enabled app is required, and deliberately not a diff-derived "affected
  apps" set, since the merge guard fails open on anything it cannot
  determine and a gate whose strictness silently shrinks on an indeterminate
  diff is not a gate. Fully additive: a `CHANGE.md` with no `apps:` key
  parses, runs, reports, and gates exactly as it did under 0.3.1. When
  `apps:` is present the root may not also declare its own
  `boot`/`lanes`/`profiles`, since a root that is simultaneously a registry
  and an app makes `--app` and `promotion.<branch>.profile` ambiguous, so
  adopting the monorepo shape is a verbatim move of the existing block into
  one app file.
  Also, from auditing a real consumer repo's single-origin ZAP scope across
  four profiles: `change_config.lanes.zap.targets` entries may now be
  relative and resolve against the lane base url, exactly as `a11y.routes`
  and `browserless.routes` already do, so a multi-path ZAP scope is
  profile-portable instead of pinning every profile to one committed host;
  an absolute entry behaves exactly as before.
  `change_config.profiles.<profile>.lanes.zap.targets` restates a scope
  spanning two genuinely distinct services per profile, the one case
  relative paths cannot express; `targets` is rejected in a profile override
  of any lane but `zap`, which is the only lane that reads it.
  `change_config.rb doctor` now prints each enabled lane's resolved target
  and warns when an absolute lane literal's host differs from the resolved
  profile's `boot.target_url` host, which catches at authoring time the
  silent mismatch that previously only surfaced as one lane auditing the
  wrong deployment. The report meta and the gate record now carry the
  resolved profile and target, not just the requested profile, so a report
  states which deployment it actually audited. `change_run.rb --target-url
  URL` and `--health-url URL` override the resolved boot target at
  invocation time, so an ephemeral preview deployment's url never has to be
  committed and hand-edited.
- 0.5.0: `contributors_team`, the third top-level block, is documented for the
  first time and gains `contributors_team.artifacts`, the team's shared
  findings-artifact area. Its presence turns on an optional final step of a
  sweep: the run's findings are rendered as a self-contained static HTML page
  carrying the contributor and git context, every lane's findings, the
  browserless lane's full-page screenshots and one recording per viewport, and
  one annotated PDF per viewport, and the bundle is uploaded to a private S3
  bucket served through CloudFront with the team index page rebuilt from a
  DynamoDB listing. Fully additive and default off: a `CHANGE.md` with no
  `artifacts:` block captures no media, builds no bundle, uploads nothing, and
  audits, reports, and gates byte for byte as it did under 0.4.0. Publishing is
  best effort and reported separately from the gate, since the four audit lanes
  are the release decision and the artifact is the evidence attached to it. No
  field here is a credential: `basic_auth` names an SSM SecureString parameter
  and a 1Password reference, and the CloudFront function that enforces HTTP
  Basic Auth carries only the SHA-256 digest of that credential, because a
  CloudFront function has no network access and cannot fetch a secret at
  request time. The first three fields (`team_id`, `public_key_ed25519`,
  `contributors[]`) are not new to the code, which has always read them; naming
  them here closes the gap where the registry covered only two of the three
  frontmatter blocks.
- 0.6.0: `contributors_team.organization`, `contributors_team.team`, and
  `contributors_team.platform` replace `contributors_team.artifacts` as the way
  a repo says where its findings artifacts go. The destination is no longer a
  bucket the team provisioned for itself; it is a hosted artifacts service, and
  publishing to it is three HTTP calls (declare the run and its files, PUT each
  file to the presigned URL that comes back, say it finished) authenticated by a
  team API key and nothing else. The client that does it carries no AWS SDK, no
  AWS credential, no bucket name, and no key prefix, because the service assigns
  the prefix, records the run, lists it on the team page, and enforces who may
  open it. `key_prefix` accordingly leaves the run manifest: a client that
  invented one would be asserting a location it has no authority over.
  `cf_artifacts_init.rb` and the per-team CloudFront Basic Auth function it
  compiled a digest into are deleted, since provisioning is now one shared
  service rather than a script run once per team. `cf_team_join.rb --platform`
  is the new second credential type, storing a team API key in the macOS
  Keychain under service `change-fabric-platform`, account
  `<organization>/<team>`, so the key lives in neither the repo nor the shell.
  `contributors_team.artifacts` is deprecated, not removed: its fields still
  parse and a repo carrying them still resolves a configuration and still builds
  its bundle, `platform:` wins whenever both are present, and the legacy block is
  removed at 0.7.0. Everything else holds: still default off, still fully
  additive, and still best effort, so a publish that fails is a named warning on
  a run whose verdict the four audit lanes alone decided.
