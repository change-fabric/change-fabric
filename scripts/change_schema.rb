#!/usr/bin/env ruby
# frozen_string_literal: true

# The canonical registry of the CHANGE.md frontmatter schema: its version and
# every field the change-fabric parser accepts. This is the single machine
# -readable source of truth that both the parsing code and the human-facing
# reference doc (skills/change/reference/CHANGE-frontmatter-spec.md) are checked
# against. The drift test (test/change_schema_spec_test.rb) fails if the doc and
# this registry disagree on the field set or the version, so a schema change
# cannot land without updating both.
#
# VERSION is the schema's own semver, independent of the cf skills toolkit's own
# version (which is carried by the repo's skills/v* release tags, not by any
# file in the tree; see RELEASING.md). Bump it only when a CHANGE.md
# frontmatter field is added, removed, or renamed, and record the change in the
# spec doc's changelog. A field-set change without a matching version bump, or a
# version bump the doc does not reflect, is exactly what the drift test catches.
module ChangeSchema
  VERSION = '0.8.0'

  # The four audit lanes, the authoritative list the config validator enforces.
  LANES = %w[k6 a11y zap browserless].freeze

  # The only top-level key an app config file (change_config.apps.<app>.config,
  # 0.4.0) may declare. Governance is repo-wide and lives only in the root
  # CHANGE.md; a change_policy: block in an app file is rejected at load rather
  # than silently ignored, since its author would otherwise believe it was
  # doing something.
  APP_FILE_TOP_KEYS = %w[change_config].freeze

  # Root change_config keys that become an error once change_config.apps
  # (0.4.0) is present: a root that is simultaneously a registry and an app
  # makes --app meaningless for that app and makes
  # change_policy.promotion.<branch>.profile ambiguous about whose profile is
  # meant.
  ROOT_APP_MODE_FORBIDDEN = %w[boot lanes profiles default_profile].freeze

  # Every accepted frontmatter field, as a dotted path. Placeholder segments are
  # literal and appear identically in the spec doc so the two match exactly:
  #   <lane>    any of the LANES above
  #   <branch>  any git branch name under promotion
  #   <profile> any name under change_config.profiles
  #   <app>     any name under change_config.apps (an app in a monorepo, 0.4.0)
  #   []        a field on each item of a list
  FIELDS = [
    # The one field outside both change_config: and change_policy: (0.3.0):
    # the schema version a CHANGE.md was authored against, compared against
    # this constant at config load to catch a toolkit/file version skew that
    # would otherwise surface later as a confusing silently-ignored field.
    'spec_version',
    # change_config: mechanical target-app details the audit lanes read.
    'change_config.project',
    'change_config.boot.up',
    'change_config.boot.down',
    'change_config.boot.network',
    'change_config.boot.target_url',
    'change_config.boot.health.url',
    'change_config.boot.health.expect_status',
    'change_config.boot.health.timeout_seconds',
    'change_config.boot.env_file',
    'change_config.lanes.<lane>.enabled',
    'change_config.lanes.<lane>.base_url',
    # basic_auth (0.3.0): only meaningful on a browser lane (a11y, browserless);
    # k6 and zap never read it and a config setting it there is rejected.
    'change_config.lanes.<lane>.basic_auth.username_env',
    'change_config.lanes.<lane>.basic_auth.password_env',
    'change_config.lanes.k6.script',
    'change_config.lanes.k6.env',
    'change_config.lanes.k6.thresholds.http_req_failed',
    'change_config.lanes.k6.thresholds.http_req_duration',
    'change_config.lanes.k6.scenario.window',
    'change_config.lanes.k6.scenario.assumptions',
    'change_config.lanes.k6.scenario.funnel[].stage',
    'change_config.lanes.k6.scenario.funnel[].value',
    'change_config.lanes.k6.scenario.funnel[].rate',
    'change_config.lanes.k6.scenario.expected_peak',
    'change_config.lanes.k6.scenario.tested_to',
    'change_config.lanes.k6.scenario.tested_rate',
    'change_config.lanes.k6.scenario.safety_margin',
    'change_config.lanes.k6.scenario.overload',
    'change_config.lanes.k6.scenario.comparison',
    'change_config.lanes.a11y.routes',
    'change_config.lanes.a11y.threshold',
    'change_config.lanes.zap.targets',
    'change_config.lanes.zap.strict',
    'change_config.lanes.zap.auth',
    'change_config.lanes.browserless.routes',
    'change_config.lanes.browserless.routes[].path',
    'change_config.lanes.browserless.routes[].auth',
    'change_config.lanes.browserless.routes[].figma.file_key',
    'change_config.lanes.browserless.routes[].figma.node_id',
    'change_config.lanes.browserless.routes[].figma.viewport',
    'change_config.lanes.browserless.viewports[].name',
    'change_config.lanes.browserless.viewports[].width',
    'change_config.lanes.browserless.viewports[].height',
    'change_config.lanes.browserless.auth.login_url',
    'change_config.lanes.browserless.auth.email_env',
    'change_config.lanes.browserless.auth.password_env',
    'change_config.lanes.browserless.auth.email_selector',
    'change_config.lanes.browserless.auth.password_selector',
    'change_config.lanes.browserless.auth.submit_selector',
    'change_config.lanes.browserless.auth.wait_for_selector',
    'change_config.lanes.browserless.auth.timeout_ms',
    'change_config.lanes.browserless.auth.steps[].url',
    'change_config.lanes.browserless.auth.steps[].fields[].selector',
    'change_config.lanes.browserless.auth.steps[].fields[].env',
    'change_config.lanes.browserless.auth.steps[].fields[].code_source.url',
    'change_config.lanes.browserless.auth.steps[].fields[].code_source.pattern',
    'change_config.lanes.browserless.auth.steps[].fields[].code_source.timeout_ms',
    'change_config.lanes.browserless.auth.steps[].fields[].code_source.poll_interval_ms',
    'change_config.lanes.browserless.auth.steps[].submit_selector',
    'change_config.lanes.browserless.auth.steps[].wait_for_selector',
    'change_config.lanes.browserless.auth.steps[].timeout_ms',
    'change_config.lanes.browserless.figma.token_env',
    'change_config.lanes.browserless.figma.max_diff_percent',
    # change_config.profiles (0.2.0): named deploy-target overrides sharing one
    # audit surface. A profile may only set project, boot.*, and a lane's
    # enabled/base_url, never its routes/thresholds/viewports, so one CHANGE.md
    # keeps a single documented audit shape across every environment instead of
    # a parallel schema per profile.
    'change_config.default_profile',
    'change_config.profiles.<profile>.project',
    'change_config.profiles.<profile>.boot.up',
    'change_config.profiles.<profile>.boot.down',
    'change_config.profiles.<profile>.boot.network',
    'change_config.profiles.<profile>.boot.target_url',
    'change_config.profiles.<profile>.boot.health.url',
    'change_config.profiles.<profile>.boot.health.expect_status',
    'change_config.profiles.<profile>.boot.health.timeout_seconds',
    'change_config.profiles.<profile>.boot.env_file',
    'change_config.profiles.<profile>.lanes.<lane>.enabled',
    'change_config.profiles.<profile>.lanes.<lane>.base_url',
    'change_config.profiles.<profile>.lanes.<lane>.basic_auth.username_env',
    'change_config.profiles.<profile>.lanes.<lane>.basic_auth.password_env',
    # profiles.<profile>.lanes.zap.targets (0.4.0): the one lane field a
    # profile may restate, for a ZAP scope spanning two genuinely distinct
    # services that a relative-path targets entry cannot express.
    'change_config.profiles.<profile>.lanes.zap.targets',
    # profiles.<profile>.lanes.browserless.auth (0.8.0): a login url and its
    # credential env vars are how a profile's environment is reached, not
    # what gets audited once the login succeeds, the same *where* vs *what*
    # distinction basic_auth and targets above already rest on. Deep-merges
    # over the base auth block, so a profile can restate just the field that
    # differs (e.g. only timeout_ms) without repeating the rest.
    'change_config.profiles.<profile>.lanes.browserless.auth.login_url',
    'change_config.profiles.<profile>.lanes.browserless.auth.email_env',
    'change_config.profiles.<profile>.lanes.browserless.auth.password_env',
    'change_config.profiles.<profile>.lanes.browserless.auth.email_selector',
    'change_config.profiles.<profile>.lanes.browserless.auth.password_selector',
    'change_config.profiles.<profile>.lanes.browserless.auth.submit_selector',
    'change_config.profiles.<profile>.lanes.browserless.auth.wait_for_selector',
    'change_config.profiles.<profile>.lanes.browserless.auth.timeout_ms',
    'change_config.profiles.<profile>.lanes.browserless.auth.steps[].url',
    'change_config.profiles.<profile>.lanes.browserless.auth.steps[].fields[].selector',
    'change_config.profiles.<profile>.lanes.browserless.auth.steps[].fields[].env',
    'change_config.profiles.<profile>.lanes.browserless.auth.steps[].fields[].code_source.url',
    'change_config.profiles.<profile>.lanes.browserless.auth.steps[].fields[].code_source.pattern',
    'change_config.profiles.<profile>.lanes.browserless.auth.steps[].fields[].code_source.timeout_ms',
    'change_config.profiles.<profile>.lanes.browserless.auth.steps[].fields[].code_source.poll_interval_ms',
    'change_config.profiles.<profile>.lanes.browserless.auth.steps[].submit_selector',
    'change_config.profiles.<profile>.lanes.browserless.auth.steps[].wait_for_selector',
    'change_config.profiles.<profile>.lanes.browserless.auth.steps[].timeout_ms',
    # change_config.apps (0.4.0): a registry of the several genuinely
    # different apps one monorepo contains, each with its own config file
    # (change_config.apps.<app>.config). See the "change_config.apps" section
    # of the spec doc; an app file's own change_config: block accepts every
    # field documented above except change_config.apps.* itself.
    'change_config.apps.<app>.config',
    'change_config.apps.<app>.path',
    'change_config.apps.<app>.description',
    'change_config.apps.<app>.enabled',
    # change_policy: machine-checkable governance the merge gate enforces.
    'change_policy.protected_branches',
    'change_policy.gate.require_change_pass',
    'change_policy.promotion.<branch>.review_required',
    'change_policy.promotion.<branch>.self_review_allowed',
    'change_policy.promotion.<branch>.require_change_pass',
    'change_policy.promotion.<branch>.ci_gate',
    'change_policy.promotion.<branch>.ci_skippable',
    # change_policy.promotion.<branch>.profile (0.2.0): scopes this branch's
    # require_change_pass gate to one named change_config profile's own
    # recorded run, instead of any profile-less comprehensive run.
    'change_policy.promotion.<branch>.profile',
    # promotion.<branch>.apps (0.4.0): restricts which change_config.apps
    # entries' comprehensive passes gate a merge into this branch. Omitted,
    # every registered enabled app is required.
    'change_policy.promotion.<branch>.apps',
    'change_policy.admin_bypass.allowed',
    'change_policy.admin_bypass.require_change_pass',
    'change_policy.admin_bypass.conditions',
    # contributors_team: (0.5.0) the third top-level block. It registers the
    # repo with a contributors team and, under `artifacts`, with that team's
    # shared findings-artifact area. The first three fields predate this
    # version in the code (contributors_team.rb has always read them) and are
    # documented here for the first time, so the registry finally covers every
    # frontmatter key change-fabric reads rather than only two of the three
    # blocks.
    'contributors_team.team_id',
    'contributors_team.public_key_ed25519',
    'contributors_team.contributors[].id',
    'contributors_team.contributors[].name',
    # contributors_team.organization / .team (0.6.0): the repo's team on the
    # hosted platform, by slug. Committed rather than derived from the API key
    # because they name the team in a form a human reading the file recognises,
    # and because together they are the Keychain account the key is stored
    # under.
    'contributors_team.organization',
    'contributors_team.team',
    # contributors_team.platform (0.6.0): publishing through the hosted
    # artifacts service. Its presence is what turns per-run artifact publishing
    # on, and what makes this the primary shape when the deprecated
    # `artifacts:` block below is also present. Nothing here is a credential:
    # `api_key_env` names the env var a team API key arrives in, never the key,
    # and `basic_auth` names env vars for the staging-wide fence in front of the
    # API, never their values. No bucket, prefix, or distribution appears here
    # at all: the service owns every one of them.
    'contributors_team.platform.enabled',
    'contributors_team.platform.api_url',
    'contributors_team.platform.api_key_env',
    'contributors_team.platform.team_id',
    'contributors_team.platform.basic_auth.username_env',
    'contributors_team.platform.basic_auth.password_env',
    'contributors_team.platform.media.screenshots',
    'contributors_team.platform.media.video',
    'contributors_team.platform.media.video_fps',
    # contributors_team.artifacts (0.5.0, DEPRECATED at 0.6.0, removed at
    # 0.7.0): the per-team S3 + CloudFront area a team provisioned for itself
    # before the hosted service existed. Still parsed, so a repo that has not
    # migrated still resolves a configuration and still builds its bundle, but
    # `platform:` above supersedes it and wins whenever both are present.
    'contributors_team.artifacts.enabled',
    'contributors_team.artifacts.bucket',
    'contributors_team.artifacts.region',
    'contributors_team.artifacts.aws_profile',
    'contributors_team.artifacts.distribution_id',
    'contributors_team.artifacts.domain',
    'contributors_team.artifacts.manifest_table',
    'contributors_team.artifacts.basic_auth.username',
    'contributors_team.artifacts.basic_auth.ssm_parameter',
    'contributors_team.artifacts.basic_auth.secret_ref',
    'contributors_team.artifacts.media.screenshots',
    'contributors_team.artifacts.media.video',
    'contributors_team.artifacts.media.video_fps'
  ].freeze
end
