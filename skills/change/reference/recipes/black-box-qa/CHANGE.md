---
spec_version: 0.12.0
change_config:
  project: vendor-app-qa
  default_profile: staging
  boot:
    # No boot.up and no boot.down: the app is already deployed and we have no source.
    # No boot.network: lanes reach the public URL directly.
    target_url: https://staging.app.example
    health:
      url: https://staging.app.example/
      expect_status: 200
      timeout_seconds: 30
  lanes:
    k6:
      enabled: false   # never load-test a host you do not operate
    a11y:
      enabled: true
      routes: ["/", "/login", "/account"]
      threshold: serious
      auth: { login_url: /login, email_env: QA_STAGING_EMAIL, password_env: QA_STAGING_PASSWORD, email_selector: "#email", password_selector: "#password", submit_selector: "button[type=submit]" }
    zap:
      enabled: true    # passive baseline; only hosts you are authorized to test
      targets: ["https://staging.app.example"]
      strict: false
    browserless:
      enabled: true
      routes: ["/", "/login", { path: "/account", auth: true }]
      viewports:
        - { name: mobile, width: 390, height: 844 }
        - { name: desktop, width: 1440, height: 900 }
      auth: { login_url: /login, email_env: QA_STAGING_EMAIL, password_env: QA_STAGING_PASSWORD, email_selector: "#email", password_selector: "#password", submit_selector: "button[type=submit]" }
    testcases:
      enabled: true
      suites: ["qa/*.cf-testcases.yml"]
      auth: { login_url: /login, email_env: QA_STAGING_EMAIL, password_env: QA_STAGING_PASSWORD, email_selector: "#email", password_selector: "#password", submit_selector: "button[type=submit]" }
  profiles:
    staging: {}
    prod:
      boot:
        target_url: https://app.example
        health: { url: https://app.example/ }
      lanes:
        zap: { enabled: false }
        a11y: { auth: { login_url: /login, email_env: QA_PROD_EMAIL, password_env: QA_PROD_PASSWORD, email_selector: "#email", password_selector: "#password", submit_selector: "button[type=submit]" } }
        browserless: { auth: { login_url: /login, email_env: QA_PROD_EMAIL, password_env: QA_PROD_PASSWORD, email_selector: "#email", password_selector: "#password", submit_selector: "button[type=submit]" } }
        testcases: { auth: { login_url: /login, email_env: QA_PROD_EMAIL, password_env: QA_PROD_PASSWORD, email_selector: "#email", password_selector: "#password", submit_selector: "button[type=submit]" } }
change_policy:
  protected_branches: [main]
  promotion:
    main:
      review_required: true
      self_review_allowed: true
      require_change_pass: true
---

# Black-box QA of a deployed app

For a team that can log in to an app but has no access to its source. This
repo is QA-only: it holds this CHANGE.md and the suites under `qa/`, nothing
else. cf:change never builds or starts anything here; every lane points at the
deployed host named in `boot.target_url`.

## Running it

```bash
cp .env.qa.example .env.qa   # then fill in real QA accounts
set -a; . ./.env.qa; set +a
# run cf:change for staging (the default profile), or with --profile prod
```

Add `.env.qa` to `.gitignore` before the first commit.

## Credentials

The lanes read their login env vars (`QA_STAGING_EMAIL` and friends) from
cf:change's own process environment, so the export line above is the only way
creds reach them. `boot.env_file` would not help: it only feeds the `boot.up`
subprocess, and this repo has no `boot.up`. Staging and prod use distinct
variable names so each profile can only ever log in with its own account.

## What the gate certifies

A passing run is recorded against this QA repo's HEAD sha. It certifies that
this suite passed against the deployment at that moment, not that any app code
change is safe. If the target is down, the health check fails and so does the
gate, which can block merges to this repo for reasons outside it. Use the
documented escape hatches (`CF_ALLOW_UNGATED_MERGE`, or a human-run
`change_override.rb`) when that happens, rather than weakening the policy.

## Security scanning

The ZAP lane runs the passive baseline: no attack payloads, but it still spiders
and sends real traffic. Point it only at hosts you are authorized to test. That
is why it is on for staging and off in the `prod` profile. k6 is off in both,
since a load test against a host you do not operate is never appropriate.
