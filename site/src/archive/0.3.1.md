# CHANGE.md frontmatter specification

Schema version: 0.3.1

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
two required top-level keys plus one optional one, followed by the prose
governance FAQ:

```
---
spec_version: "0.3.0"   # optional: the schema version this file was authored against
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

### spec_version (0.3.0): pinning a file to the schema it was authored against

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `spec_version` | string | no | The schema version (this document's "Schema version" line) `CHANGE.md` was authored against. Compared against the installed toolkit's `ChangeSchema::VERSION` at every config load; a mismatch never blocks a run, but surfaces a named warning (`doctor`, and at the top of a real sweep) rather than letting a field the installed toolkit does not understand yet (or no longer emits) fail silently. Omit it and nothing is checked. |

## Conventions in the field tables

Field paths are dotted. Placeholder segments are literal and mean:

- `<lane>`: any of the four lanes, `k6`, `a11y`, `zap`, `browserless`.
- `<branch>`: any git branch name (a promotion target such as `staging`).
- `<profile>`: any name under `change_config.profiles` (a deploy target such as `staging`).
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
*what* it audits.

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
| `change_policy.admin_bypass.allowed` | boolean | no (default false) | Whether admin-bypass merging (`gh pr merge --admin`) is permitted at all for a protected branch. |
| `change_policy.admin_bypass.require_change_pass` | boolean | no (default true) | Whether an allowed admin bypass still requires the cf:change gate to have passed. |
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
this document). It is independent of the repo's `VERSION` file, which versions
the whole cf skills toolkit. Adding, removing, or renaming a frontmatter field
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
`change-schema/v<version>` git tag suffix without escaping, since hyphen and
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
`change-schema/v<version>` convention) and only merge the stable version to
`main`, which is what the site and its `/spec` index track.

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
