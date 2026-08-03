---
name: cf:change
description: Deterministic, config-driven release-gate sweep. Runs all four dockerized audit lanes (k6 load, axe-core accessibility, OWASP ZAP pentest, browserless responsive UX) against a project's change-fabric config, aggregates every finding into one CSV and Markdown report on the Desktop, and records a pass/fail gate for the head commit. Invocable directly and gated into cf:drive.
---

# CF Change (change fabric)

The comprehensive, unattended release-gate sweep. One file per project, the
repo-root `CHANGE.md`, tells the platform how to boot the target app and what to
audit (its `change_config:` frontmatter) and how the repo is governed (its
`change_policy:` frontmatter); this skill runs all four dockerized lanes against
it and produces one shareable report pair plus a gate record for the PR's head
commit.

Trigger: `/cf:change [<PR, branch, or target description>]`.

Question: would this change survive a release-quality sweep of load,
accessibility, security, and responsive UX, deterministically and on the record?

## cf:change vs cf:qa

Both drive browsers in an ephemeral browserless container, but they are
different tools:

- `cf:qa` is ad hoc, model-scoped, natural-language-driven. It scopes a
  Playwright smoke plan from a described flow, clarifies ambiguity with the
  user, and explores. Use it for exploratory UAT of a specific feature.
- `cf:change` is deterministic and config-driven. It reads the repo-root
  `CHANGE.md` and runs a fixed four-lane audit (load, a11y, security, responsive
  UX) with no per-run scoping decisions, meant to run unattended before a
  release-affecting merge. It writes a reproducible report and records a
  pass/fail gate the merge hook enforces.

Reach for `cf:qa` to investigate; reach for `cf:change` to gate.

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

**Monorepos (0.4.0).** A repo with more than one genuinely different app (not
just a different deploy target of the same app; that is what
`change_config.profiles` is for) declares a registry instead:
`change_config.apps.<name>.config` points at that app's own
`apps/<name>/CHANGE.app.yml`, a config-only file (its only accepted top-level
key is `change_config:`; governance stays repo-wide in the root `CHANGE.md`).
`reference/CHANGE.app.template.yml` is the annotated starting point for an app
file. See `reference/CHANGE-frontmatter-spec.md`'s `change_config.apps` section
for the full shape. A repo with no `change_config.apps` key is completely
unaffected: single-app mode is a registry of exactly one entry, the root file
itself.

## Workflow

1. **Resolve scope.** A PR (read its head, check it out so the run happens on
   the head commit), a branch, or a target description. The gate record is keyed
   by the git head SHA, so run against the exact commit that will merge.
2. **Confirm the config.** Ensure a `CHANGE.md` with a `change_config:`
   frontmatter block exists at the target repo root. If it does not, this repo is
   not change-fabric-integrated yet; say so and stop rather than guessing an
   audit surface. Scoping a target from a description follows cf:qa's phase 1-5
   shape only where the config leaves a choice open; the config is the source of
   truth for what to audit. `CHANGE.md` must be self-contained: reject or flag a
   config that cites another tool's own internal conventions (a coding harness's
   config vocabulary, an unrelated CLAUDE.md table) instead of stating the
   target app's own boot and audit details directly.
3. **Run the sweep.** From the target repo root:
   `ruby ~/.claude/cf/bin/change_run.rb all`. Add `--profile NAME` to run a
   named profile from `change_config.profiles` (a real staging or production
   target) instead of the base config. In a monorepo (`change_config.apps`),
   a bare `all` sweeps every registered, enabled app in turn and passes only
   if all of them do; add `--app NAME` (repeatable) to narrow the sweep to one
   or more named apps, composing with `--profile` exactly as it always has (a
   per-app deploy-target selector, resolved independently for each app in the
   sweep). `--target-url URL` and `--health-url URL` override the resolved
   boot target at invocation time, so an ephemeral preview deployment's url
   never has to be committed and hand-edited. This boots the app per the
   config, waits for its health signal, stands up the ephemeral runners
   (digest-pinned, `--rm`, per cf:docker), runs k6, a11y, ZAP, and browserless
   lanes, tears everything down, writes the report pair to `~/Desktop` (one
   pair per app, plus a Markdown roll-up index when the sweep covers more than
   one app), and records the gate under the head SHA (and the profile, when
   one was given). Exit 0 means every app's every lane passed, 1 means a lane
   in any app failed, 2 means a setup failure (no docker, bad config, app
   never ready).
4. **Report.** Summarize the per-lane pass/fail and the failing findings from
   the Markdown report. Name both report paths (the `.md` and the `.csv`) so the
   run is reproducible and shareable.
5. **Publish the findings artifact (optional, 0.32.0).** Only when the repo's
   `CHANGE.md` carries a `contributors_team.platform:` block. See "The findings
   artifact" below. Report the published url and any artifact warning
   separately from the gate; a failed publish never changes the run's verdict.

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
- `lanes.zap`: `enabled`, `targets` (list of in-scope urls; an entry may be
  relative, resolved against the lane base url, or absolute; omit entirely to
  scan the lane base url itself; prefer relative when `profiles` exist, since
  an absolute entry is a fixed value no profile can override), `strict` (fail
  on any low-or-above alert; default fails only on high-risk), optional `auth`
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

A repo with more than one real deploy target (a local Docker stack, a real
staging or production deployment) declares each as a named profile under
`change_config.profiles` rather than a second `CHANGE.<env>.md` file; see
`reference/CHANGE-frontmatter-spec.md`'s profiles section. `change_run.rb all
--profile staging` runs a named profile, and `change_policy.promotion.<branch>.
profile` scopes that branch's merge gate to the matching profile's own pass.

### Monorepos

`change_config.profiles` changes *where* one app's audit runs, never *what* it
audits; it cannot express a second app with different routes, a different
boot, and no auth at all. `change_config.apps` is the axis for that: a
registry, each entry naming an app's own `CHANGE.app.yml`
(`config`, optional `path`/`description`/`enabled`). An app file's `boot`,
`lanes`, and `profiles` behave exactly as a single-app `CHANGE.md`'s do, and
its repo-relative paths and boot commands resolve against the repo root, not
the app file's own directory. The root cannot declare `change_config.apps`
alongside its own `boot`/`lanes`/`profiles`/`default_profile`; adopting the
monorepo shape is a verbatim move of that block into one app file.
`change_policy.promotion.<branch>.apps` restricts which apps' passes gate a
branch; omitted, every registered enabled app is required. See the frontmatter
spec's `change_config.apps` section for the full field set and a worked
example, and `reference/CHANGE.app.template.yml` for the app-file template.

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

## The findings artifact (0.32.0)

A repo that registers a `contributors_team.platform:` block gets one more step
after the gate is recorded: the run's findings become a shareable, durable web
page instead of a report pair on one person's Desktop. A repo without the block
is completely unaffected, and no part of this step can change a run's pass/fail.

What gets built, into one bundle directory on the Desktop:

- `index.html`, a self-contained static page: who ran the sweep (contributor id
  and name resolved from the team registration) and when, the team's registered
  roster, the branch, head commit, and PR the run covered, every lane's findings
  in one filterable table, and a section per viewport.
- Per viewport: the full-page screenshot of every route walked at that viewport
  as real inline images, a `<video controls>` recording of that viewport's whole
  route walk, and a link to that viewport's annotated PDF.
- `manifest.json`, the machine-readable record of all of the above, plus a copy
  of the run's own Markdown and CSV report.

How the media is captured. The browserless lane already walks every route at
every viewport in one page inside the browserless container; with an artifacts
block it also screenshots each cell and records the walk. The recording is
assembled inside Chromium (a CDP screencast of the page being walked, drawn onto
a canvas in a second page whose `captureStream()` feeds a `MediaRecorder`) and
comes back base64 in the same response, because the container shares no
filesystem with the host. The video is written next to the page and referenced
as a sibling asset, never inlined as a data URI: a data-URI video would have to
be fully downloaded before the page renders, while a sibling file streams from
CloudFront and lets the browser fetch only what is played. A viewport whose
recording fails is a warn finding naming the reason, never a silently missing
video.

The per-viewport PDF is rendered through the `cf:pdf-rendering` convention
(Puppeteer `page.pdf()` with explicit format and margins, escaped template data,
local assets only, screenshots inlined as data URIs since the rendering browser
is in a container with no access to host files). Annotations are interleaved
captions under each screenshot rather than boxes drawn on it: the lanes report
selectors and whole-page measurements, never element rectangles, so a drawn box
would mean inventing coordinates on an evidence artifact.

Where it publishes. `scripts/change_artifact_publish.rb` publishes the bundle to
the hosted artifacts service in three calls: `POST /v1/artifacts` declares the
run and every file in it and comes back with one presigned upload URL per file,
each file's bytes go straight to storage over its own URL, and
`POST /v1/artifacts/:id/complete` says the upload finished. The service then
checks what actually landed against what was declared, records the run, and
lists it on the team's findings page in the platform web app.

The client authenticates with a team API key sent as `x-cf-key` and holds
nothing else. It requires only Ruby's standard library: no AWS SDK, no AWS
profile, no bucket name, no distribution id, and no key prefix, because the
service assigns the prefix (`<organization>/<team>/<short-id>/`) and owns the
index. That is also why the run manifest carries no `key_prefix`: a client that
invented one would be asserting a location it has no authority over.

Where the key comes from, in order: the env var named by
`contributors_team.platform.api_key_env` (default `CF_TEAM_API_KEY`), then this
machine's Keychain entry under service `change-fabric-platform`, account
`<organization>/<team>`, which `ruby ~/.claude/cf/bin/cf_team_join.rb --platform
<organization> <team> --stdin` writes. The key is never in `CHANGE.md`.

Who can read a published run is the service's decision, not the client's. A
person's browser trades their session for CloudFront signed cookies scoped to
their team's whole prefix; a machine trades its team API key for presigned
download URLs. Neither path is something a publishing repo configures.

Provisioning is not a per-team step at all any more. The artifacts service is
one shared, Terraform-managed deployment (`platform/infra`), and joining it is
creating a team in the web app and minting that team's API key. Add
`--no-publish` to `change_run.rb` to build the bundle without publishing it.

## Lane subsets

The single-lane skills run one lane each with the same config and report
shape but record only their own scope (never the comprehensive gate the merge
hook requires): `cf:k6`, `cf:a11y`, `cf:zap`. The browserless responsive
lane has no standalone skill; it runs as part of `cf:change`.

## Failure modes

- Docker unavailable, or a runner image cannot be pulled: `change_run.rb` exits
  2 and names the cause. Report it and stop; never fall back to a host daemon.
- No `CHANGE.md` with a `change_config:` block: the repo is not integrated. The
  error names the template and spec doc to author one against. Run
  `ruby ~/.claude/cf/bin/change_config.rb doctor` against a `CHANGE.md` in
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
- Leftover `cf-change-*` containers or networks from a run that crashed before
  its teardown: `ruby ~/.claude/cf/bin/change_run.rb sweep` force-removes any
  not owned by the current run.
- Root registers `change_config.apps` but also declares its own
  `boot`/`lanes`/`profiles`/`default_profile`: a load error naming both keys.
  A root that is simultaneously a registry and an app makes `--app` meaningless
  for that one app and makes `change_policy.promotion.<branch>.profile`
  ambiguous about whose profile is meant; move the conflicting block into one
  app's own `CHANGE.app.yml`.
- No team API key is resolvable, the artifacts service is unreachable, or it
  refuses the key: the run's lanes, report, and gate are unaffected and the
  publish step reports the failure as its own line, naming the env var to set
  and the `cf_team_join.rb --platform` command that stores one. The bundle is
  still on the Desktop either way. Drop the `platform:` block to opt out
  entirely.
- Some presigned uploads succeed and others fail: the ones that succeeded are
  counted, the ones that did not are named one line each, and completion still
  runs, so the service's own check reports exactly which files never arrived
  rather than the run silently claiming a bundle it does not have.
- The repo still carries the deprecated 0.5.0 `contributors_team.artifacts:`
  block: the bundle is built but nothing is published, and the warning names the
  migration. The publisher carries no AWS SDK or AWS credential at all, so the
  per-team bucket path cannot be taken; replace the block with `organization`,
  `team`, and `platform:` (the legacy block is removed at schema 0.7.0).
- A viewport's recording fails (no MediaRecorder, a screencast that never
  attaches): a warn finding names the viewport and the reason, and the artifact
  says so in place of that viewport's video. The rest of the artifact publishes.
- A very large route matrix can exceed browserless's request payload limit when
  the per-viewport PDF is rendered (every screenshot travels inline). The PDF
  step reports it per viewport and the page, media, and upload still publish;
  narrow `lanes.browserless.routes`, or set `artifacts.media.screenshots: false`
  to publish findings without captures.
- An app has no passing record for the head SHA: the merge guard denies,
  naming exactly which app(s) are missing and the `--app` re-run command
  (e.g. `change_run.rb all --profile production --app scattergram`).
