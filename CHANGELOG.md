# Changelog

The release history of the **CHANGE.md frontmatter specification**, the schema
carried by `ChangeSchema::VERSION` in `scripts/change_schema.rb` and mirrored by
the "Schema version" line at the top of
`skills/change/reference/CHANGE-frontmatter-spec.md`.

This is not the version of the cf skills toolkit. That one is carried by the
repo's `skills/v*` release tags, has no file in the tree, and moves on its own
schedule: a toolkit release usually changes no schema field at all, and a schema
release is often a small part of a much larger toolkit release.

Every version below has a frozen, permanently addressable rendering at
`https://www.changefabric.org/spec/<version>`, plus its raw markdown at
`/spec/<version>.md`. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the schema follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) as scoped to the
field set: major for a removed, renamed or newly required field, minor for a new
optional field, patch for a documentation-only clarification.

## [0.10.0] - 2026-08-22

A fifth lane, `testcases`, runs regression cases committed to the repo, and
four fields that were already live are documented for the first time.

### Added

- `change_config.lanes.testcases.*`: `suites` (globs naming sidecar suite
  files), `tags`, `gate_tags`, `viewport.name` / `.width` / `.height`,
  `timeout_ms`, and the full `auth.*` login block, field for field the same
  shape `lanes.browserless.auth` already defines.
- `change_config.profiles.<profile>.lanes.testcases.auth.*`. A profile may
  override exactly `base_url`, `basic_auth.*` and `auth.*` on this lane: where
  a case is pointed, never what it checks.
- `change_policy.promotion.<ref>.require_testcases`, which additionally
  requires the recorded comprehensive pass for that branch to carry a passing
  `testcases` lane. Fails closed: a record with no entry for the lane is not a
  pass.
- `change_config.lanes.<lane>.wait_for.load_state` / `.selector` /
  `.url_contains` / `.url_matches` / `.timeout_ms`,
  `change_config.lanes.browserless.routes[].wait_for`,
  `change_config.lanes.<lane>.retries`,
  `change_config.lanes.browserless.cell_isolation`, and
  `change_config.lanes.browserless.locale`. All five behaviors already shipped;
  they were written under a change forbidden to bump the schema and so had no
  registry row or spec entry until now.

### Changed

- Cases are never inline in `CHANGE.md`. A suite file is a sidecar
  (`<dir>/<name>.cf-testcases.yml`) with its own schema registry, its own spec
  doc (`skills/testcases/reference/suite-file-spec.md`) and its own drift test,
  so a new step verb does not need a `CHANGE.md` schema bump.
- `targets` is still rejected on every lane but `zap`. The testcases lane reads
  no target list, and a scope list nothing reads is worse than no scope.

## [0.9.0] - 2026-08-22

Trunk + tag releases: a repo with one trunk and release tags instead of
long-lived staging/production branches can now be governed and gated too.

### Added

- `change_policy.promotion` accepts a `tag:`-prefixed key (`tag:staging/v*`)
  alongside branch keys, in the same map. Every field a branch rule carries
  (`require_change_pass`, `profile`, `apps`, `review_required`, `ci_gate`,
  `ci_skippable`) means exactly the same thing on a tag rule. `branch:<name>`
  is an explicit synonym for an unprefixed key.
- `change_policy.protected_refs`, the superset of `protected_branches` that
  also accepts `tag:<glob>` entries, unioned with `protected_branches` and
  with every key under `promotion:`.
- `change_policy.promotion.<ref>.environment`, a human label for a promotion
  target used in deny messages and `doctor` output.
- `change_policy.promotion.<ref>.require_trunk_ancestor` and
  `.require_prior_tag`, tag-rule-only fields that restore what a branch
  topology encodes structurally (a commit's promotion order and provenance)
  for a topology that has to state it instead.
- `change_tag_guard.rb`, a `PreToolUse` hook gating the tag *push* (a matching
  `git push`, or `gh release create`) on a passing `cf:change` run recorded
  for the exact commit, sharing its gate question with `change_merge_guard.rb`
  through the new `ChangeGateCheck`.
- `change_run.rb all --for-tag <tagname>`, which resolves a tag against its
  matching `promotion` rules and sweeps the profile(s) they name against the
  commit the tag points at.
- `change_run.rb gate-status [--ref REF]`, a read-only check (no docker, no
  boot, no lanes) of whether a ref's matching rules are already satisfied.
- `reference/CHANGE.trunk-tags.example.md`, a complete copy-paste `CHANGE.md`
  for the trunk + tag topology.

### Compatibility

Fully additive. A `CHANGE.md` with no `tag:` key anywhere parses, runs,
reports, and gates exactly as it did under 0.8.0. `protected_branches` is
retained unchanged, not deprecated, and `change_tag_guard.rb` never fires on a
repo with no tag rule.

## [0.8.0] - 2026-08-21

A profile may override the browserless lane's login flow, so one audit surface
can reach environments whose logins differ.

### Added

- `change_config.profiles.<profile>.lanes.browserless.auth.*`, a per-profile
  override of the base `browserless.auth` block, deep-merged field by field.
  Every field of the base block is overridable: `login_url`, `email_env`,
  `password_env`, the four selectors, `timeout_ms`, and the multi-step
  `steps[]` shape down to each field's `env` and `code_source`.

### Compatibility

Fully additive. A `CHANGE.md` whose profiles declare no `browserless.auth`
override parses, runs, reports, and gates exactly as it did under 0.6.0.
`auth` in a profile override of any other lane is rejected at load, with the
same message shape `basic_auth`'s own lane guard already uses, since no other
lane reads it.

### Note

0.7.0 is deliberately skipped, not missing. It stays reserved for the
`contributors_team.artifacts` removal that 0.6.0 announced, which is a
breaking field-set change and has not shipped yet.


## [0.6.0] - 2026-08-02

Findings artifacts publish through a hosted service instead of a bucket each
team provisions for itself.

### Added

- `contributors_team.organization` and `contributors_team.team`, the two slugs
  that address a repo's team on the hosted platform. Their presence is what
  enables the artifact pipeline.
- `contributors_team.platform`, with `enabled`, `api_url`, `api_key_env`,
  `team_id`, `basic_auth.username_env`, `basic_auth.password_env`, and
  `media.screenshots` / `media.video` / `media.video_fps`.
- `ruby scripts/cf_team_join.rb --platform <organization> <team> --stdin`, a
  second credential type that stores a team API key in the macOS Keychain under
  service `change-fabric-platform`, account `<organization>/<team>`, so the key
  is in neither the repo nor the shell.
- `ruby scripts/cf_team_migrate.rb --org <slug> --email <you>`, which carries an
  already registered team onto the platform in one run: the organization, a team
  carrying the old `team_id` as its `legacyTeamId` and the old public key, your
  own membership, one contributor alias per roster entry, a repo link, and a
  team API key.

### Changed

- Publishing is three HTTP calls against the artifacts service (declare the run
  and its files, PUT each file to the presigned URL that comes back, complete
  the run), authenticated by a team API key and nothing else. The client carries
  no AWS SDK, no AWS credential, no bucket name and no key prefix.
- `key_prefix` left the run manifest. The service assigns the prefix, so a
  client that invented one would be asserting a location it has no authority
  over.
- `contributors_team.team_id`, `public_key_ed25519` and `contributors[]` are
  explicitly **not** deprecated and have no removal version. They remain what
  the presence and secret-alert capabilities read: this machine's identity
  resolves from them, the telemetry Lambdas verify signatures against the public
  key, and the `cf-teams` table is keyed on `team_id`. A migrated repo carries
  both sets of fields permanently.

### Deprecated

- `contributors_team.artifacts`, the per-team S3 bucket that predates the hosted
  service. Its fields still parse and a repo carrying them still resolves a
  configuration; `platform` wins whenever both are present. Removed at 0.7.0.

### Removed

- `scripts/cf_artifacts_init.rb` and the per-team CloudFront Basic Auth function
  it compiled a credential digest into. Provisioning is now one shared service
  rather than a script run once per team.

### Compatibility

Additive. A `CHANGE.md` with no `platform` block captures no media, builds no
bundle, publishes nothing, and audits, reports and gates exactly as it did under
0.5.0. Publishing stays best effort and separate from the gate: a failed publish
is a named warning on a run whose verdict the four audit lanes alone decided.

## [0.5.0] - 2026-08-01

`contributors_team` is documented for the first time, and gains a
findings-artifact pipeline.

### Added

- `contributors_team` enters the field registry. `team_id`,
  `public_key_ed25519` and `contributors[].id` / `contributors[].name` were
  always read by the code; until now the registry covered only two of the three
  frontmatter blocks.
- `contributors_team.artifacts`, the team's shared findings-artifact area, with
  `enabled`, `bucket`, `region`, `aws_profile`, `distribution_id`, `domain`,
  `manifest_table`, `basic_auth.username` / `basic_auth.ssm_parameter` /
  `basic_auth.secret_ref`, and `media.screenshots` / `media.video` /
  `media.video_fps`.
- `ruby scripts/cf_artifacts_init.rb <team_id>`, one human-run command that
  creates the bucket, the distribution, the Basic Auth CloudFront function and
  the manifest table, then prints the `artifacts` block filled in.

### Changed

- With `artifacts` present, a completed sweep renders its findings as one
  self-contained static HTML page carrying the run's contributor and git
  context, every lane's findings, the browserless lane's full-page screenshots,
  one recording per viewport and one annotated PDF per viewport, uploads the
  bundle to the private bucket behind CloudFront, and rebuilds the team index
  from a DynamoDB listing.

### Security

- No field in the block is a credential. `basic_auth` names an SSM SecureString
  parameter and a 1Password reference, never a value, and the CloudFront
  function enforcing HTTP Basic Auth carries only the SHA-256 digest of that
  credential, because a CloudFront function has no network access and cannot
  fetch a secret at request time.

### Compatibility

Additive and default off. A `CHANGE.md` with no `artifacts` block captures no
media, builds no bundle, uploads nothing, and audits, reports and gates byte for
byte as it did under 0.4.0.

## [0.4.0] - 2026-07-27

One repo can register several genuinely different apps, and a ZAP scope can
travel between deploy targets.

### Added

- `change_config.apps`, a registry of the several genuinely different apps one
  monorepo contains, each pointing at its own config file (conventionally
  `<app-dir>/CHANGE.app.yml`) carrying its own `boot`, `lanes` and `profiles`.
  This is the axis `profiles` deliberately does not cover: a profile changes
  where one audit runs, never what it audits.
- `change_policy.promotion.<branch>.apps`, restricting which apps' passes gate a
  branch. Omitted, every registered enabled app is required, deliberately not a
  diff-derived "affected apps" set.
- `change_run.rb --app NAME` (repeatable), composing with `--profile`.
- `change_run.rb --target-url URL` and `--health-url URL`, overriding the
  resolved boot target at invocation time, so an ephemeral preview deployment's
  url never has to be committed and hand-edited.

### Changed

- `change_config.lanes.zap.targets` entries may be relative and resolve against
  the lane base url, exactly as `a11y.routes` and `browserless.routes` already
  do. An absolute entry behaves exactly as before.
- `change_config.profiles.<profile>.lanes.zap.targets` restates a scope spanning
  two genuinely distinct services, the one case relative paths cannot express.
  `targets` is rejected in a profile override of any other lane.
- A bare sweep runs every registered enabled app and passes only if all of them
  pass. The gate record for a head SHA carries a per-app map and merges across
  separate `--app` runs instead of overwriting, with the existing top-level
  `scope` and `status` retained as the aggregate.
- `change_config.rb doctor` prints each enabled lane's resolved target and warns
  when an absolute lane literal's host differs from the resolved profile's
  `boot.target_url` host. The report meta and gate record carry the resolved
  profile and target, not just the requested profile.

### Compatibility

Additive. A `CHANGE.md` with no `apps` key parses, runs, reports and gates
exactly as it did under 0.3.1. When `apps` is present the root may not also
declare its own `boot`, `lanes` or `profiles`, so adopting the monorepo shape is
a verbatim move of the existing block into one app file.

## [0.3.1] - 2026-07-22

Documentation only, no field-set change.

### Added

- The pre-release identifier convention (`-alpha.N` and `-beta.N`, SemVer
  2.0.0) for floating a target version before it is final.

### Changed

- The `spec_version_mismatch` warning notes when either side of a mismatch is a
  pre-release schema, since a skew against a field set that is still actively
  changing is a different thing from a skew between two stable releases.

## [0.3.0] - 2026-07-22

### Added

- `change_config.lanes.<lane>.basic_auth.username_env` and `.password_env`, and
  the matching profile override, for a browser lane (`a11y`, `browserless`)
  hitting a target behind HTTP Basic Auth. Names of environment variables, never
  values.
- Top-level `spec_version`, compared against the installed toolkit's
  `ChangeSchema::VERSION` at every config load. A mismatch never blocks a run
  but raises a named warning, instead of a field silently not doing what its
  author expected.

### Changed

- Basic Auth is answered through the browser's own authentication hook, never by
  embedding credentials in the url. A `https://user:pass@host` url loads fine,
  but the Fetch spec forbids constructing a request from a url carrying
  credentials, so any same-origin `fetch()` the loaded page makes would throw
  and crash the page.
- Setting `basic_auth` on a non-browser lane (`k6`, `zap`), at the base config
  or in a profile override, is rejected at load rather than silently accepted as
  a credential its author believes is doing something.

## [0.2.0] - 2026-07-22

### Added

- `change_config.profiles`, named deploy-target overrides (a local Docker stack,
  a real staging or production deployment) sharing one audit surface instead of
  a separate `CHANGE.<env>.md` per environment. A profile may set `project`,
  `boot.*`, and a lane's `enabled` and `base_url`, deep-merged over the base
  `change_config`.
- `change_config.default_profile`, and `change_run.rb --profile NAME` to select
  one.
- `change_policy.promotion.<branch>.profile`, scoping a branch's gate to one
  named profile's own recorded pass, so a passing staging run never satisfies a
  production promotion gate.

## [0.1.0] - 2026-07-21

Initial pre-release specification, dogfooded end to end against real consumer
repos before its first tagged release.

### Added

- The single-file `CHANGE.md` frontmatter, consolidating the mechanical config
  (formerly a separate `.cf/change.yml`) and the governance policy into
  `change_config` and `change_policy` blocks alongside the prose body.
- Authenticated browserless checks and Figma visual alignment: `routes[]` as a
  mapping with `path`, `auth` and `figma`, a lane-level `auth` login flow, and a
  `figma` pixel-diff block.
- `boot.env_file`, sourcing a compose `build.args` entry's `${VAR}`
  interpolation into the `boot.up` subprocess environment.
- `lanes.browserless.auth.steps[]`, a multi-step login where each step carries
  its own `url`, `fields[]`, `submit_selector`, `wait_for_selector` and
  `timeout_ms`. This covers a login needing more than one form, such as an OTP
  flow that submits an email and then a code from a second form, with a field's
  value resolved from `env` or from a `code_source` that polls an HTTP endpoint
  live rather than reading, storing or logging the code on the host.
