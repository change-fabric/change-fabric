---
spec_version: 0.12.0
change_config:
  project: acme-monorepo
  # Once apps: is present the root is a registry only: boot, lanes, and
  # profiles live in each app's own CHANGE.app.yml.
  apps:
    web:
      config: apps/web/CHANGE.app.yml
      path: apps/web
      description: Next.js app with a login
change_policy:
  protected_branches: [main]
  promotion:
    main:
      review_required: true
      self_review_allowed: true
      require_change_pass: true
  admin_bypass:
    allowed: false
    require_change_pass: true
---

# Change management for acme-monorepo

A pnpm workspace with one Next.js app, `apps/web`, that sits behind an email
and password login. The root file only registers the app and states the merge
policy; the boot command and the lanes live in `apps/web/CHANGE.app.yml`, so a
second app later is one more registry entry and one more app file.

## How to run

From the repo root:

```bash
set -a; . ./.env.qa; set +a
ruby ~/.claude/cf/scripts/change_run.rb all
```

`boot.up` installs the workspace and starts `next dev` in the background with
a pidfile, `boot.down` stops it. The lanes run in containers and reach the dev
server at `host.docker.internal:3000`.

## QA credentials

The a11y, browserless, and testcases lanes log in as a QA user whose email and
password come from `QA_EMAIL` and `QA_PASSWORD`. Copy `.env.qa.example` to
`.env.qa`, fill it in, keep `.env.qa` in `.gitignore`, and export it with the
`set -a` line above before every run.

`boot.env_file` does not do this job. It is merged only into the environment
of the `boot.up` subprocess (here, the app's own `apps/web/.env.local`), while
the lanes read the environment of the cf:change process itself. Credentials
the lanes need must be exported in the shell that starts the run.
