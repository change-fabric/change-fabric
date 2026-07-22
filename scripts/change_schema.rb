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
# VERSION is the schema's own semver, independent of the repo's VERSION file
# (which versions the whole pst skills toolkit). Bump it only when a CHANGE.md
# frontmatter field is added, removed, or renamed, and record the change in the
# spec doc's changelog. A field-set change without a matching version bump, or a
# version bump the doc does not reflect, is exactly what the drift test catches.
module ChangeSchema
  VERSION = '0.1.0'

  # The four audit lanes, the authoritative list the config validator enforces.
  LANES = %w[k6 a11y zap browserless].freeze

  # Every accepted frontmatter field, as a dotted path. Placeholder segments are
  # literal and appear identically in the spec doc so the two match exactly:
  #   <lane>   any of the LANES above
  #   <branch> any git branch name under promotion
  #   []       a field on each item of a list
  FIELDS = [
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
    # change_policy: machine-checkable governance the merge gate enforces.
    'change_policy.protected_branches',
    'change_policy.gate.require_change_pass',
    'change_policy.promotion.<branch>.review_required',
    'change_policy.promotion.<branch>.self_review_allowed',
    'change_policy.promotion.<branch>.require_change_pass',
    'change_policy.promotion.<branch>.ci_gate',
    'change_policy.promotion.<branch>.ci_skippable',
    'change_policy.admin_bypass.allowed',
    'change_policy.admin_bypass.require_change_pass',
    'change_policy.admin_bypass.conditions'
  ].freeze
end
