---
contributors_team:
  team_id: changefabric-core
  public_key_ed25519: 3BXo6b9PO7gy35dZT1i7Znsaky4sOPn9b6V5JwdnW+4=
  contributors:
    - { id: pst, name: Patrick Taylor }

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
  promotion:
    main:
      review_required: false
      self_review_allowed: true
      require_change_pass: true
      ci_gate: "ci.yml: rubocop, TypeScript typecheck (npm run typecheck), rake test"
      ci_skippable: false
  admin_bypass:
    allowed: false
    require_change_pass: true
    conditions: "not used; the maintainer merges every PR by hand once CI and the pst:change gate are both green, per this repo's own CLAUDE.md"
---

# Change management for pstaylor-patrick/change-fabric

The straight-answer governance FAQ for this repo. Point a teammate here when
they ask how a change reaches `main`, whether every PR needs a review, or
whether the maintainer can approve their own work.

## Git flow

Trunk-based on a single long-lived branch, `main`. A change lands on a
feature branch, opens a PR into `main`, and merges are squash merges. There
are no `staging`/`production` branches: this repo ships a skills-and-hooks
toolkit plus a static docs site (`site/`), not a deployed multi-environment
service.

## What is required before promoting to main

Every PR into `main` must have CI green: `ci.yml` runs `bundle exec
rubocop`, a TypeScript typecheck (`npm run typecheck`), and `bundle exec
rake test`. This is not currently skippable. A merge review is not required
in practice today (see self-review below), but the comprehensive `pst:change`
audit gate must still have passed for the head commit before merge, which
the change-fabric merge hook enforces regardless.

## Who can review, and is self-review allowed

This repo currently has a single active maintainer, so self-review is the
actual practice. GitHub itself blocks a literal self-approval review (`gh pr
review --approve` on your own PR fails), so approval on this repo typically
comes from an agent-driven review (`pst:code-review`, `pst:drive`) rather
than a second human. The maintainer still merges every PR by hand; this
repo's own `CLAUDE.md` states that explicitly, and no agent should run `gh
pr merge` here without being told to.

## When admin-bypass merging is and is not acceptable

- **Not acceptable, ever, on this repo**: `gh pr merge --admin` bypassing
  the normal review or CI wait. This repo's `CLAUDE.md` states plainly that
  the maintainer merges every PR manually; an agent should push, open or
  update the PR, and get CI and the `pst:change` gate green, then stop and
  wait to be told to merge.
- CI must be green and the comprehensive `pst:change` audit must have
  passed for the head commit before a merge happens at all, regardless of
  who performs it.

## What CI gates main

`ci.yml`'s single `ci` job: `bundle exec rubocop`, a TypeScript smoke
typecheck (`npm run typecheck`), then `bundle exec rake test`. Not
skippable. Additionally, the change-fabric merge-gating hook
(`change_merge_guard.rb`) requires a passing comprehensive `pst:change` run
recorded for the PR's head SHA before `gh pr merge` into `main` is allowed.
