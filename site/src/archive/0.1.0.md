# CHANGE.md frontmatter specification

Schema version: 0.1.0

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
two top-level keys, followed by the prose governance FAQ:

```
---
change_config:
  ...        # mechanical target-app details the audit lanes read
change_policy:
  ...        # machine-checkable governance the merge gate enforces
---

# Change management for <repo>
...prose FAQ...
```

There is no separate config file. A repo can carry only `CHANGE.md`, with none
of the audit tools installed as its own dependencies; the platform supplies each
runner as an ephemeral, digest-pinned container.

`reference/CHANGE.template.md` is a complete, copyable starting point. This spec
is the field-by-field authority behind it.

## Conventions in the field tables

Field paths are dotted. Placeholder segments are literal and mean:

- `<lane>`: any of the four lanes, `k6`, `a11y`, `zap`, `browserless`.
- `<branch>`: any git branch name (a promotion target such as `staging`).
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
| `change_config.lanes.zap.targets` | list of string | no (default the lane base url) | URLs in scope for the ZAP baseline. |
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
| `change_policy.promotion.<branch>.require_change_pass` | boolean | no (default true) | Gates a merge into this branch on a passing comprehensive pst:change run for the head SHA. |
| `change_policy.promotion.<branch>.ci_gate` | string | no | The CI that must be green to promote (read by humans; explained in prose). |
| `change_policy.promotion.<branch>.ci_skippable` | boolean | no | Whether that CI gate can be skipped, and the prose says by whom. |
| `change_policy.admin_bypass.allowed` | boolean | no (default false) | Whether admin-bypass merging (`gh pr merge --admin`) is permitted at all for a protected branch. |
| `change_policy.admin_bypass.require_change_pass` | boolean | no (default true) | Whether an allowed admin bypass still requires the pst:change gate to have passed. |
| `change_policy.admin_bypass.conditions` | string | no | The repo's stated condition for an acceptable admin bypass, surfaced in the gate's deny reason. |

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

For a full example of every field, see `reference/CHANGE.template.md`.

## Versioning and changelog

The schema carries its own semantic version (`ChangeSchema::VERSION` in
`scripts/change_schema.rb`, mirrored by the "Schema version" line at the top of
this document). It is independent of the repo's `VERSION` file, which versions
the whole pst skills toolkit. Adding, removing, or renaming a frontmatter field
is a schema change: bump this version, update `scripts/change_schema.rb`, and
record the change below in the same pass. The drift test fails if the field set
or the version here and in the code disagree, so a schema change cannot land
half-done.

Version scheme (semver for the schema):

- Major: a breaking change (a field removed or renamed, a required field added,
  a type or meaning change that invalidates existing files).
- Minor: a backward-compatible addition (a new optional field).
- Patch: a documentation-only clarification with no field-set change.

### Changelog

- 0.1.0: initial pre-release specification, dogfooded end to end against real
  consumer repos before its first tagged release. Consolidates the mechanical
  config (formerly a separate `.pst/change.yml`) and the governance policy
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
