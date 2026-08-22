---
# A complete, copy-paste CHANGE.md for a trunk + tag release topology (schema
# 0.9.0): one long-lived branch, main, with higher environments named
# by release tags (staging/v1.4.0, production/v1.4.0) instead of long-lived
# staging/production branches. Copy this file to <repo-root>/CHANGE.md and
# edit; for the branch-per-environment default, start from CHANGE.template.md
# instead. See the frontmatter spec's "change_policy tag rules" section for
# the full field reference this file uses.
#
# The tag: rules below are validated by `change_config.rb doctor` and
# enforced at push time by `change_tag_guard.rb`: publishing a matching tag
# with no recorded passing run for that commit is denied. Run
# `change_run.rb all --for-tag <tagname>` against the commit being tagged
# first (it sweeps the right profile against the right commit), or
# `change_run.rb gate-status --ref <tagname>` to check without running
# anything, then push the tag.

spec_version: "0.9.0"

change_config:
  project: my-app
  default_profile: local

  boot:
    up: docker compose up -d --build app
    down: docker compose down
    target_url: http://my-app:3000
    health:
      url: http://localhost:3000/health

  lanes:
    a11y:
      routes: ["/", "/login", "/dashboard"]
      threshold: serious
    zap:
      targets: ["/", "/login"]
      strict: false
    browserless:
      routes: ["/", "/login"]
      viewports:
        - { name: mobile, width: 390, height: 844 }
        - { name: desktop, width: 1440, height: 900 }
    k6:
      thresholds:
        http_req_failed: "rate<0.01"
        http_req_duration: "p(95)<500"

  # One app, three real places it runs. A tag release selects a profile; it
  # does not replace profiles, which still answer WHERE an audit runs.
  profiles:
    local: {}
    staging:
      project: my-app-staging
      boot:
        up: "true"
        down: "true"
        target_url: https://staging.my-app.example
        health: { url: https://staging.my-app.example/health }
    production:
      project: my-app-production
      boot:
        up: "true"
        down: "true"
        target_url: https://my-app.example
        health: { url: https://my-app.example/health }

change_policy:
  # Only one long-lived branch. Higher environments are tags on it, so they
  # are named here as tag patterns rather than as branches.
  protected_refs:
    - main
    - "tag:staging/v*"
    - "tag:production/v*"

  promotion:
    # Branch rule: unchanged semantics, gated at `gh pr merge` time.
    main:
      review_required: true
      self_review_allowed: true
      require_change_pass: true
      profile: local
      ci_gate: "lint, typecheck, unit, build"
      ci_skippable: false

    # Tag rules: gated at tag-push time (git push of the tag, or
    # gh release create) once a later schema phase enforces it. The tagged
    # commit is already on main; what the gate adds is that this exact commit
    # passed the staging/production audit surface before it was released.
    tag:staging/v*:
      environment: staging
      require_change_pass: true
      profile: staging
      require_trunk_ancestor: main
      ci_gate: "the same ci.yml run that gated the merge to main"
      ci_skippable: false

    tag:production/v*:
      environment: production
      require_change_pass: true
      profile: production
      require_trunk_ancestor: main
      # Production releases only a commit already released to staging: the
      # trunk-topology equivalent of "production merges only from staging".
      require_prior_tag: "staging/v*"
      review_required: true
      self_review_allowed: false
      ci_gate: "lint, typecheck, unit, e2e, build"
      ci_skippable: false

  admin_bypass:
    allowed: false
    require_change_pass: true
    conditions: "not used; a release is a tag push, gated by the recorded audit for that commit"
---

# Change management for my-app

The straight-answer governance FAQ for this repo. Point a teammate here when
they ask how a change reaches production, whether every release needs a
review, or whether an author can cut their own release.

## Git flow

One long-lived branch, `main`. Work happens on short-lived feature branches
and lands on `main` by squash-merged PR. There are no `staging` or
`production` branches. A release to a higher environment is a tag pushed at a
commit already on `main`: `staging/v1.4.0`, then `production/v1.4.0` at that
same commit once it has been verified in staging. Deploys are triggered by
the tag, not by change-fabric; this file gates the release, it does not
perform it.

## What is required before promoting to each environment

- To `main`: a reviewed PR, CI green, and a passing comprehensive `cf:change`
  run for the head commit under the `local` profile.
- To staging: run `cf:change` against the exact commit being tagged, then
  push the tag `staging/v1.4.0`. The commit must already be on `main`.
- To production: the same, tagging `production/v1.4.0`, and the commit must
  already carry a `staging/v*` tag (this is what `require_prior_tag` states
  machine-checkably above).

## Who can review, and is self-review allowed

- Merging to `main`: any teammate may review; the author may not merge their
  own change without a second approval.
- Cutting a `staging/v*` tag: the author who merged to `main` may cut it
  themselves; no second review is required, since the audit gate is the real
  check.
- Cutting a `production/v*` tag: requires a second person's review of the
  release itself (not just the original merge), stated by
  `self_review_allowed: false` above.

## When admin-bypass merging is and is not acceptable

Not used in this repo. There is no `staging`/`production` branch to
admin-merge into; a release is a tag push, which this file gates on the
recorded audit for that exact commit rather than on a merge-time bypass.

## What CI gates each stage

- Merging to `main`: lint, typecheck, unit tests, build.
- Tagging `staging/v*`: the same `ci.yml` run that already gated the merge to
  `main`, re-verified for the exact commit being tagged.
- Tagging `production/v*`: lint, typecheck, unit tests, e2e, build, all green
  for the exact commit being tagged.
