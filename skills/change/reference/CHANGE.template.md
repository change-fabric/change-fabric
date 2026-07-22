---
# CHANGE.md is the single change-fabric file. Copy it to <repo-root>/CHANGE.md
# and edit. Its frontmatter carries an optional spec_version plus two blocks:
#
#   spec_version:   the schema version this file is authored against (optional;
#                   compared to the installed toolkit at load, warns on drift).
#   change_config:  the mechanical target-app details the audit lanes read
#                   (boot, health, routes, thresholds, viewports).
#   change_policy:  the machine-checkable governance the merge gate enforces.
#
# The prose body below both blocks is the human governance FAQ. There is no
# separate config file: a repo can carry only this one file, with none of the
# audit tools installed as its own dependencies, and the platform provides every
# runner as an ephemeral, digest-pinned container.
#
# CHANGE.md must be self-contained: it must not cite or depend on another
# tool's own internal conventions (a coding harness's config vocabulary, an
# unrelated CLAUDE.md table). It is read by change-fabric alone.
#
# This template shows a single deploy target. A repo with more than one real
# target (a local Docker stack plus a real staging/production deployment)
# names each as a change_config.profiles entry instead; see the frontmatter
# spec's "Multiple deploy targets (profiles)" worked example.

spec_version: "0.3.0"

change_config:
  project: my-app                 # label used in the Desktop report filename

  boot:
    # Command that brings the target app up. Run from the repo root. May be a
    # docker compose invocation or anything that ends with the app reachable.
    #
    # `up` must return promptly and leave the app running in the background; it
    # is not waited on beyond its own exit. `docker compose up -d` already
    # detaches. A foreground command (for example `pnpm dev`) blocks forever and
    # the run hangs before the health check is ever reached: self-detach it
    # first, for example `nohup pnpm dev >/tmp/app.log 2>&1 & echo $! >/tmp/app.pid`,
    # with a matching `down` that kills the recorded pid.
    #
    # If the target's own compose file publishes a host port or container_name
    # that collides with something already running on this host, fix it through
    # the target's own supported mechanism (an env var the compose file reads
    # for its port mapping, a dedicated audit compose profile) rather than
    # editing the tracked compose file. A `docker-compose.override.yml` cannot
    # remap a published port away: Compose concatenates `ports:` lists across
    # base and override rather than replacing them, so the base port is still
    # bound.
    up: docker compose up -d --build postgres migrate portal core
    # Repo-relative env file(s) parsed (simple KEY=VALUE lines, not shell
    # `source`) and merged into the `up` command's own subprocess environment.
    # Compose resolves a service's `build.args: { KEY: ${VAR} }` from your shell
    # or a project-root .env, never from that service's own `env_file:`, so a
    # build needing NEXT_PUBLIC_*-style build args fails inside the build tool
    # with no docker-level warning unless VAR is already exported. Name the file
    # here so change-fabric sources it before running `up`, instead of the
    # author having to pre-export it. Omit if `up` needs no such vars.
    env_file: .env.local
    # Teardown, always run after the sweep. `docker compose down` alone leaves
    # named volumes (a Postgres volume, for example) intact across runs, which
    # is fine only when the app's seed data is fully idempotent. If a second run
    # re-seeding on top of the first risks a constraint failure, tear the volume
    # down too: `docker compose down -v`, at the cost of a slower next boot.
    down: docker compose down
    # An existing docker network the runners join so they can reach app services
    # by name. Omit to have the platform create an ephemeral network; then
    # address the app from the runners via host.docker.internal.
    network: myapp_default
    # In-network base url the lanes default to (service-name form when on a
    # compose network). A per-lane base_url overrides this.
    target_url: http://myapp-portal:3000
    health:
      # HOST-reachable url, polled from the host via curl. A local dev stack
      # behind a local CA (a Caddy dev cert) works: curl trusts the system store
      # and honors SSL_CERT_FILE/SSL_CERT_DIR if set.
      #
      # Prefer a published host port here (created by the same `up` command
      # change-fabric ran) over a named host routed through a separately-running
      # reverse proxy (a shared Caddy container, for example). The proxy is not
      # part of this run's compose project, so a fresh ephemeral boot's
      # container is never wired into it; the health poll gets no response even
      # though the app itself came up healthy.
      url: http://localhost:3000/health
      expect_status: 200
      timeout_seconds: 120

  lanes:
    k6:
      enabled: true
      # Repo-relative k6 script. Omit to use the platform's built-in light-load
      # default (a constant-VU GET against a health route).
      script: apps/load/scripts/smoke.js
      env:
        BASE_URL: http://myapp-core:3000
        VUS: "5"
        DURATION: "30s"
        # HEALTH_PATH: /api/health   # the built-in default script's target route;
        # omit to default it to boot.health.url's own path (below)
      thresholds:                 # applied to the built-in default script
        http_req_failed: "rate<0.01"
        http_req_duration: "p(95)<500"
      # Optional narrative inputs for the Markdown report (never the CSV). All
      # optional; supply what you have. Numbers here are illustrative only.
      scenario:
        window: "per minute"
        assumptions: "25% open rate, 10% of opens click through, 5% of those attempt the action"
        funnel:
          - { stage: "campaign emails sent", value: 100000 }
          - { stage: "opened", rate: 0.25 }
          - { stage: "clicked through", rate: 0.10 }
          - { stage: "attempted the action", rate: 0.05 }
        expected_peak: "125 per minute"   # optional; derived from the funnel when omitted
        tested_to: "300 requests/second sustained for 5 minutes, zero errors, p95 180ms"
        tested_rate: 18000        # optional numeric (same unit as window) to compute the margin multiple
        safety_margin: "well over 100x the expected peak"  # used only when tested_rate is absent
        overload: "a burst to 5x the ceiling degraded by queuing rather than dropping; the queue drained in about 8 seconds"
        comparison: "sustained throughput comparable to a well-known public launch's first-day growth rate"

    a11y:
      enabled: true
      routes: ["/login", "/register", "/home", "/dashboard"]
      threshold: serious          # minor | moderate | serious | critical
      base_url: http://myapp-portal:3000   # optional per-lane override
      # Only set this when the target itself sits behind HTTP Basic Auth (not
      # the same thing as the browserless lane's form-based auth: below).
      # Names of env vars, never real values; answered via page.authenticate(),
      # never a url-embedded credential (the Fetch spec forbids it). Rejected
      # at load on k6/zap, since neither lane reads it.
      # basic_auth:
      #   username_env: PORTAL_BASIC_AUTH_USER
      #   password_env: PORTAL_BASIC_AUTH_PASSWORD

    zap:
      enabled: true
      targets:
        - http://myapp-portal:3000
        - http://myapp-core:3000
      strict: false               # true: any low-or-above alert fails; false: only high-risk fails
      auth: null                  # reserved for authenticated scans; the baseline runs unauthenticated

    browserless:
      enabled: true
      # A route can be a plain string (unauthenticated, no visual check) or a
      # mapping that adds auth: true (checked only after the login flow below
      # succeeds) and/or a figma: block (pixel-diffed against a real Figma
      # reference render of that node).
      routes:
        - "/login"
        - path: /home
          figma: { file_key: tg3U3gNcIYMn9aY9JYrIZc, node_id: "12:345", viewport: desktop }
        - path: /dashboard
          auth: true
          figma: { file_key: tg3U3gNcIYMn9aY9JYrIZc, node_id: "12:678" }
      viewports:
        - { name: mobile, width: 390, height: 844 }
        - { name: tablet, width: 768, height: 1024 }
        - { name: desktop, width: 1440, height: 900 }
      base_url: http://myapp-portal:3000
      # Configures a one-time login the browserless session runs before any
      # auth: true route, using the resulting cookies for the rest of the run.
      # Real credentials only, read from the named env vars (never written
      # here); a route needing auth is skipped with a named failing finding
      # rather than checked unauthenticated when this is absent or incomplete.
      auth:
        login_url: /login
        email_env: PORTAL_TEST_EMAIL
        password_env: PORTAL_TEST_PASSWORD
        email_selector: 'input[name="email"]'      # optional, this is the default
        password_selector: 'input[type="password"]' # optional, this is the default
        submit_selector: 'button[type="submit"]'     # optional, this is the default
        wait_for_selector: '[data-testid="dashboard"]' # optional post-login confirmation
        timeout_ms: 15000
      # A login that needs more than one form (an OTP flow: submit an email,
      # then submit a code from a second form) uses auth.steps instead of the
      # shorthand fields above; use one or the other, never both. A step's
      # field value comes from env (as above) or code_source, which polls an
      # HTTP endpoint reachable from the browserless container (e.g. a Mailpit
      # dev inbox on the run network) for the code live, rather than ever
      # reading, storing, or logging a real OTP on the host:
      #
      # auth:
      #   steps:
      #     - url: /login
      #       fields:
      #         - { selector: 'input[name="email"]', env: PORTAL_TEST_EMAIL }
      #       submit_selector: 'button[type="submit"]'
      #       wait_for_selector: 'input[name="otp"]'
      #     - fields:
      #         - selector: 'input[name="otp"]'
      #           code_source:
      #             url: http://mailpit:8025/api/v1/messages/latest
      #             pattern: '\b(\d{6})\b'
      #       submit_selector: 'button[type="submit"]'
      #       wait_for_selector: '[data-testid="dashboard"]'
      # Lane-level Figma settings shared by every route's figma: block above.
      figma:
        token_env: FIGMA_ACCESS_TOKEN   # optional, this is the default
        max_diff_percent: 10            # optional, this is the default; above it, the route's diff finding fails

# Machine-checkable policy the change-fabric merge gate enforces. The prose below
# is the human source of truth; this block states the same rules in the form the
# hook (change_merge_guard.rb) can act on. Keep the two in agreement.
change_policy:
  # Branches whose merges are gated. Every branch named under promotion: is
  # protected automatically; list extras here if needed.
  protected_branches: [staging, production]

  # Per-environment promotion rules. Each key is the branch a promotion merges
  # INTO. require_change_pass gates that merge on a passing comprehensive
  # cf:change run for the head SHA. The other keys are read by humans and
  # explained in the prose; state them honestly.
  promotion:
    staging:
      review_required: true
      self_review_allowed: true
      require_change_pass: true
      ci_gate: "lint, typecheck, unit, build"
      ci_skippable: false
    production:
      review_required: true
      self_review_allowed: true
      require_change_pass: true
      ci_gate: "lint, typecheck, unit, e2e, build"
      ci_skippable: false

  # When admin-bypass merging (gh pr merge --admin, skipping the normal review
  # or CI wait) is permitted at all. Set allowed: true only if the prose below
  # states plainly when it is acceptable. require_change_pass keeps the audit
  # gate on even for a bypass, so "allowed" never means "ungated".
  admin_bypass:
    allowed: false
    require_change_pass: true
    conditions: "state the exact condition here, e.g. CI green on the head commit"
---

# Change management for <repo>

The straight-answer governance FAQ for this repo. Point a teammate here when
they ask how a change reaches production, whether every promotion needs a
review, or whether an author can approve their own work. Keep it honest: it
should describe how this repo actually operates, not an idealized flow nobody
follows.

## Git flow

Describe the branching model in one short paragraph. For a branch-per-environment
repo: name the long-lived branches (for example `development`, `staging`,
`production`), what each represents, and how a change moves from one to the next
(feature branch -> `development`, then promotion PRs `development` -> `staging`
-> `production`). For a trunk-based repo: say so, name the trunk, and describe
how releases are cut. State whether merges are squash or merge-commit.

## What is required before promoting to each environment

Answer directly, per stage. Do not leave "does everything have a merge review
before promotion" ambiguous.

- Promoting to <staging>: is a merge review required for every change, or only
  some? What CI must be green? Is that CI gate ever skippable, and if so when?
- Promoting to <production>: same three answers. If production is stricter than
  staging (an extra reviewer, e2e that does not run earlier), say exactly how.

## Who can review, and is self-review allowed

Answer the "do TLs review their own changes" question plainly.

- Who is allowed to review and approve a promotion PR.
- Whether self-review (the same person who authored the change approving or
  merging it, including a tech lead reviewing their own work) is allowed, and
  under what conditions if so. If the repo currently relies on self-review or
  author-merge because it has a single maintainer or a small team, state that
  honestly rather than implying a second reviewer always exists.

## When admin-bypass merging is and is not acceptable

Give a direct rule, not "sometimes it is fine".

- The exact conditions under which `gh pr merge --admin` (skipping the normal
  review or CI wait) is acceptable here. If the honest answer is that this repo
  admin-merges routinely once CI is green, including the author merging their
  own work when no separate reviewer is available, write that down as the actual
  policy and name the guardrail that still applies (for example: the
  comprehensive cf:change audit gate must still have passed for the head
  commit, which the merge hook enforces).
- The conditions under which it is NOT acceptable (for example: a red CI, an
  unresolved review thread, a change to auth or billing that a second person
  must see regardless).

## What CI gates each stage

List the actual jobs that must pass to promote into each protected branch, and
state for each whether it can be skipped and by whom. This is the list the merge
gate and any reviewer should be able to check against.
