---
contributors_team:
  # The legacy registration, untouched. These three fields are what the
  # presence and secret-alert hooks read (scripts/contributors_team.rb, the
  # cf-teams DynamoDB table), and nothing below changes that. They are not
  # deprecated and have no removal version.
  team_id: changefabric-core
  public_key_ed25519: 3BXo6b9PO7gy35dZT1i7Znsaky4sOPn9b6V5JwdnW+4=
  contributors:
    - { id: pst, name: Patrick Taylor }
  # The hosted platform, added by scripts/cf_team_migrate.rb. The team above is
  # the same team: it carries `changefabric-core` as its legacyTeamId and the
  # same public key. Nothing here is a credential; api_key_env and basic_auth
  # name environment variables, never values.
  organization: change-fabric
  team: core
  platform:
    api_url: https://api.staging.changefabric.org
    api_key_env: CF_TEAM_API_KEY
    basic_auth:
      username_env: CF_PLATFORM_BASIC_AUTH_USER
      password_env: CF_PLATFORM_BASIC_AUTH_PASSWORD

change_config:
  project: changefabric-site

  boot:
    # site/ is a static Vite + React SPA with no backend of its own (see
    # site/README.md). `npm run dev` runs in the foreground, so it is
    # self-detached here per the change-fabric boot contract.
    up: "cd site && npm ci && (nohup npm run dev -- --port 5173 --strictPort >/tmp/changefabric-site.log 2>&1 & echo $! >/tmp/changefabric-site.pid)"
    down: "kill \"$(cat /tmp/changefabric-site.pid)\" 2>/dev/null; rm -f /tmp/changefabric-site.pid"
    target_url: http://localhost:5173
    health:
      url: http://localhost:5173/
      expect_status: 200
      timeout_seconds: 60

  lanes:
    # No meaningful load surface: a static single-page build with no API or
    # database behind it. Left disabled rather than run against nothing.
    k6:
      enabled: false

    a11y:
      enabled: true
      routes: ["/", "/spec", "/spec/0.1.0"]
      threshold: serious

    zap:
      enabled: true
      targets: ["http://localhost:5173"]
      strict: false
      auth: null

    browserless:
      enabled: true
      routes:
        - "/"
        - "/spec"
        - "/spec/0.1.0"
      viewports:
        - { name: mobile, width: 390, height: 844 }
        - { name: tablet, width: 768, height: 1024 }
        - { name: desktop, width: 1440, height: 900 }
      base_url: http://localhost:5173

change_policy:
  protected_branches: [main]
  # Merging to main stages work; nothing ships until a maintainer pushes the
  # matching release tag. The three tag namespaces below are the actual release
  # events for this repo's three tracks, so they are gated here alongside main.
  # See RELEASING.md for the runbook each one belongs to.
  protected_refs:
    - main
    - "tag:skills/v*"
    - "tag:spec/v*"
    - "tag:site/v*"
  promotion:
    main:
      review_required: false
      self_review_allowed: true
      require_change_pass: true
      ci_gate: "ci.yml: rubocop, TypeScript typecheck (npm run typecheck), rake test"
      ci_skippable: false

    # Tag rules, gated at tag-push time by change_tag_guard.rb. No profile:/apps:
    # on any rule; this file declares neither, so both would name nothing. No
    # require_prior_tag either: it wants a published tag at the same commit, which
    # suits staging-then-production and not three independent namespaces. The
    # prose sections below explain both choices.
    tag:skills/v*:
      environment: toolkit release
      require_change_pass: true
      require_trunk_ancestor: main
      ci_gate: "the ci.yml run that gated the merge to main, plus release-skills.yml's own tag checks"
      ci_skippable: false

    tag:spec/v*:
      environment: spec release
      require_change_pass: true
      require_trunk_ancestor: main
      ci_gate: "the ci.yml run that gated the merge to main, plus release-spec.yml's version-agreement checks"
      ci_skippable: false

    tag:site/v*:
      environment: production site
      require_change_pass: true
      require_trunk_ancestor: main
      ci_gate: "the ci.yml run that gated the merge to main, plus deploy-site.yml's version and spec-release checks"
      ci_skippable: false
  admin_bypass:
    allowed: false
    require_change_pass: true
    conditions: "not used; the maintainer merges every PR by hand once CI and the cf:change gate are both green, per this repo's own CLAUDE.md"
---

# Change management for change-fabric/change-fabric

The straight-answer governance FAQ for this repo. Point a teammate here when
they ask how a change reaches `main`, whether every PR needs a review, or
whether the maintainer can approve their own work.

## Git flow

Trunk-based on a single long-lived branch, `main`. A change lands on a
feature branch, opens a PR into `main`, and merges are squash merges. There
are no `staging`/`production` branches: this repo ships a skills-and-hooks
toolkit plus a static docs site (`site/`), not a deployed multi-environment
service.

Landing on `main` is not shipping. Nothing is released or deployed until a
maintainer pushes the matching tag, one of `skills/vX.Y.Z` (the toolkit),
`spec/vX.Y.Z` (the CHANGE.md frontmatter specification) or `site/vX.Y.Z`
(production `changefabric.org`). Each tag has its own publish workflow. The
toolkit's version is the tag itself and there is no file to edit; the other
two carry a version file the tag is checked against. The model and the runbook
are in `RELEASING.md`.

Because the release event is a tag push rather than a merge, the three tag
namespaces are protected refs in their own right, gated at push time by
`change_tag_guard.rb`.

## What is required before promoting to main

Every PR into `main` must have CI green: `ci.yml` runs `bundle exec
rubocop`, a TypeScript typecheck (`npm run typecheck`), and `bundle exec
rake test`. This is not currently skippable. A merge review is not required
in practice today (see self-review below), but the comprehensive `cf:change`
audit gate must still have passed for the head commit before merge, which
the change-fabric merge hook enforces regardless.

## What is required before cutting a release tag

A `skills/v*`, `spec/v*` or `site/v*` tag may only be pushed at a commit that
is already an ancestor of `main` and that has its own passing comprehensive
`cf:change` run recorded. Landing on `main` does not carry that pass forward:
run `ruby scripts/change_run.rb all --for-tag <tagname>` against the exact
commit being tagged, or `ruby scripts/change_run.rb gate-status --ref <ref>`
to check without running anything, then push the tag.

No track requires a prior tag at the same commit. The three tracks release
independently on their own cadences, and version ordering within each track is
already checked by that track's own publish workflow, not by this file.

## Who can review, and is self-review allowed

This repo currently has a single active maintainer, so self-review is the
actual practice. GitHub itself blocks a literal self-approval review (`gh pr
review --approve` on your own PR fails), so approval on this repo typically
comes from an agent-driven review (`cf:code-review`, `cf:drive`) rather
than a second human. The maintainer still merges every PR by hand; this
repo's own `CLAUDE.md` states that explicitly, and no agent should run `gh
pr merge` here without being told to.

## When admin-bypass merging is and is not acceptable

- **Not acceptable, ever, on this repo**: `gh pr merge --admin` bypassing
  the normal review or CI wait. This repo's `CLAUDE.md` states plainly that
  the maintainer merges every PR manually; an agent should push, open or
  update the PR, and get CI and the `cf:change` gate green, then stop and
  wait to be told to merge.
- CI must be green and the comprehensive `cf:change` audit must have
  passed for the head commit before a merge happens at all, regardless of
  who performs it.

## What CI gates main

`ci.yml`'s single `ci` job: `bundle exec rubocop`, a TypeScript smoke
typecheck (`npm run typecheck`), then `bundle exec rake test`. Not
skippable. Additionally, the change-fabric merge-gating hook
(`change_merge_guard.rb`) requires a passing comprehensive `cf:change` run
recorded for the PR's head SHA before `gh pr merge` into `main` is allowed.

## What CI gates a release tag

No CI runs on the tag itself beyond its own publish workflow's checks:
`release-skills.yml` (plain semver, newly created, strictly above every
existing `skills/v*` tag), `release-spec.yml` (tag agrees with
`ChangeSchema::VERSION`, the spec doc's `Schema version` line and a matching
`CHANGELOG.md` section) and `deploy-site.yml` (tag agrees with `site/VERSION`,
and the spec version it would publish as current is already released). The
functional CI is the `ci.yml` run that gated the merge to `main` for that same
commit. On top of both, `change_tag_guard.rb` requires the recorded `cf:change`
pass described above.
