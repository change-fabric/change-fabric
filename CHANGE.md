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
    # The per-viewport walk recording runs in real time inside the same
    # browserless call as the scan, and with 21 route/viewport cells it
    # overran browserless's function timeout on every sweep. Screenshots stay
    # on; the recording is off until the lane records outside that call.
    media:
      video: false

change_config:
  project: changefabric-site

  design:
    # The site's token file is the brand palette. cf:diagram resolves it into
    # diagram roles (scripts/diagram_palette.rb), so diagrams in this repo
    # match changefabric.org.
    tokens: site/src/styles.css

  boot:
    # site/ is a static Vite + React SPA with no backend of its own (see
    # site/README.md). The audit serves the production build with `vite
    # preview`, not the dev server: it is what actually deploys, and the dev
    # server compiles modules on demand, which made the browserless lane's
    # 21 route/viewport cells overrun browserless's function timeout. The
    # preview server runs in the foreground, so it is self-detached here per
    # the change-fabric boot contract. `--host` binds every interface, not
    # just loopback: the lanes run in containers and reach this process over
    # the docker bridge, which a 127.0.0.1-only listener refuses.
    # site/vite.config.ts allows the host.docker.internal Host header that
    # arrives with those requests.
    up: "cd site && npm ci && npm run build && (nohup npm run preview -- --port 5173 --strictPort --host 0.0.0.0 >/tmp/changefabric-site.log 2>&1 & echo $! >/tmp/changefabric-site.pid)"
    # The pid file holds the `npm run preview` wrapper, not the vite process
    # it spawns, so killing it alone leaves the server holding 5173. The next
    # run then boots into "port already in use", and its health check passes
    # against the stale server it did not start: a run that audits the
    # previous checkout. The pkill covers the child by its own command line.
    # The bracket in `[v]ite` keeps that pattern from matching the teardown
    # shell's own command line, which would have it kill itself and report a
    # failed teardown for a teardown that worked.
    down: "kill \"$(cat /tmp/changefabric-site.pid)\" 2>/dev/null; pkill -f '[v]ite preview --port 5173 --strictPort' 2>/dev/null; rm -f /tmp/changefabric-site.pid"
    # Since spec 0.17.0 boot.up and boot.down see only PATH, HOME,
    # DOCKER_HOST, TERM and the CF_CHANGE_* values, plus the names listed
    # here. npm ci, the build and the preview server need nothing more
    # (checked under `env -i PATH HOME TERM`), so the list is explicitly
    # empty.
    env: []
    # No boot.network: this app is booted on the host, not in compose, so the
    # runners reach it by the spec's host alias. `health.url` stays on
    # localhost because that poll runs on the host, not in a container.
    target_url: http://host.docker.internal:5173
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
      routes:
        - "/"
        - "/spec"
        - "/spec/0.1.0"
        - "/changelog"
        - "/reference"
        - "/reference/skills/away"
        - "/reference/skills/diagram"
        - "/reference/skills/walkthrough"
        - "/reference/skills/narrate"
        - "/reference/hooks/away_guard.rb"
      threshold: serious

    zap:
      enabled: true
      targets: ["http://host.docker.internal:5173"]
      strict: false
      auth: null

    browserless:
      enabled: true
      routes:
        - "/"
        - "/spec"
        - "/spec/0.1.0"
        - "/changelog"
        - "/reference"
        - "/reference/skills/away"
        - "/reference/skills/diagram"
        - "/reference/skills/walkthrough"
        - "/reference/skills/narrate"
        - "/reference/hooks/away_guard.rb"
      viewports:
        - { name: mobile, width: 390, height: 844 }
        - { name: tablet, width: 768, height: 1024 }
        - { name: desktop, width: 1440, height: 900 }
      base_url: http://host.docker.internal:5173

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
  # Only a phone passkey approval with a console receipt stands for a step
  # approval or an override, checked against these pins. Gates read this block
  # from the default branch (or the PR base), never the working tree.
  require_approval_proof: passkey
  approval_pins:
    receipt_key_fingerprint: "sha256:14184f67113b8eb2c2f1b6a4d1c10e241e4c9d2a4bad299fc955537b9a2def3b"
    rp_id: d7cnimvl6wqykxfkrphbbmufxu0zybds.lambda-url.us-east-1.on.aws
  admin_bypass:
    # The merge guard reads `allowed` only for `gh pr merge --admin`. A plain
    # `gh pr merge --squash` by an agent session in admin-bypass mode takes the
    # normal path, which promotion.main's require_change_pass already gates on a
    # passing comprehensive cf:change run for the head SHA. No guard change is
    # needed for the ready bar; the carve-outs are policy, not code.
    allowed: true
    require_change_pass: true
    # The carve-out files, read from the PR base. Nothing enforces the list
    # yet; the merge guard classifies PRs by it in a later release.
    carve_out_paths:
      - CHANGE.md
      - PRINCIPLES.md
      - AGENTS.md
      - install.rb
      - hooks/**
      - scripts/*guard*.rb
      - scripts/change_gate_check.rb
      - scripts/change_policy.rb
      - scripts/change_trust.rb
      - scripts/change_trust_files.rb
      - scripts/change_*_store.rb
      - scripts/cf_host_hook.rb
      - scripts/approval_console*.rb
      - scripts/approval_console/**
      - scripts/change_prod_*.rb
      - approval_console/**
      - platform/infra/**
      - site/infra/**
      - .github/workflows/cf-prod.yml
      - .github/workflows/release-*.yml
      - .github/workflows/bump-tap-formula.yml
    conditions: "the coordinating agent may squash-merge a PR only when it is rebased on main, CI is green, mergeStateStatus is CLEAN, it has 0 unresolved review threads, and a passing comprehensive cf:change run is recorded for the exact head SHA; a PR touching the merge or tag guards, the review gate, the sensitive-term or secret hooks, this change_policy block, the merge rules in AGENTS.md or PRINCIPLES.md, or a release workflow escalates to the maintainer, as does a thread contesting a settled decision, red CI or cf:change after three fix attempts, or a conflict needing a design choice; release tags, the Homebrew release, change_approve and change_override stay human-only and are handed over as a ready-to-run script under ~/.claude/cf/manual/, not a question: a change_approve the cf:change run needs is handed over before the audit, and post-merge release steps after the merge, batched across merges where possible"
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
than a second human. The coordinating agent squash-merges a PR itself once it
meets the ready bar in `admin_bypass.conditions` above; carve-out PRs and
escalation cases go to the maintainer, who merges them by hand.

## When admin-bypass merging is and is not acceptable

- **Acceptable**: a plain `gh pr merge --squash` by the coordinating agent
  in admin-bypass mode, once the PR is rebased on `main`, CI is green,
  `mergeStateStatus` is `CLEAN`, it has 0 unresolved review threads, and a
  passing comprehensive `cf:change` run is recorded for the exact head SHA.
  The agent reports one line per merge (PR URL, SHA, why it met the bar, top
  adversarial gap) and asks no question.
- **Escalate to the maintainer, never agent-merged**: any PR touching
  `scripts/change_merge_guard.rb`, `scripts/change_tag_guard.rb`,
  `scripts/change_gate_check.rb`, `scripts/change_gate_store.rb`,
  `scripts/change_policy.rb`, `scripts/change_override_store.rb`,
  `scripts/change_trust.rb`, `scripts/change_tag_refs.rb`,
  `scripts/guarded_command.rb`, `scripts/review_gate.rb`,
  `scripts/review_ack.rb`, `scripts/review_key.rb`, `scripts/review_prompt.rb`,
  `scripts/review_queue.rb`, `scripts/review_scope.rb`,
  `scripts/client_name_guard.rb`, `scripts/sensitive_terms.rb`,
  `scripts/secrets_read_guard.rb`, `scripts/key_paste_guard.rb`,
  `scripts/secret_ack.rb`, `scripts/secret_alert_poll.rb`, this file's
  `change_policy` block, the merge rules in `AGENTS.md` or `PRINCIPLES.md`,
  `.github/workflows/release-*.yml`, `bump-tap-formula.yml`, `deploy-site.yml`
  or any `.github/workflows/tag-*.yml`. Also escalate when a review thread
  contests a settled maintainer decision or the agent would rebut a P1 rather
  than fix it, when CI or `cf:change` is still red after three fix attempts,
  or when a merge conflict needs a design choice.
- **Human-only, always**: release tags (`skills/v*`, `spec/v*`, `site/v*`),
  the Homebrew release, `change_approve`, `change_override` and
  `CF_ALLOW_UNGATED_MERGE`. The agent never runs or sets them; it hands over
  the absolute path of a ready-to-run script under `~/.claude/cf/manual/`
  rather than asking. A `change_approve` the `cf:change` run needs (a changed
  `boot.up`, for one) is handed over before the audit, since the gate cannot
  pass without it. Release steps follow the merge (normally
  `release-toolkit.sh`), batched across merges where it can.
- `gh pr merge --admin` is gated on the same `cf:change` pass.

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
