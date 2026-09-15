---
name: cf:a11y
description: Runs just the accessibility lane of the change-fabric platform against a project's config. Drives axe-core against each configured route inside an ephemeral browserless Chromium container, grades violations against an impact threshold, and writes a CSV and Markdown report to the Desktop. Invocable directly for a standalone accessibility check.
---

# CF a11y

The standalone accessibility lane of the change-fabric platform. Runs only the
axe-core audit; for the full four-lane release sweep use `cf:change`.

Trigger: `/cf:a11y [<target>]`.

Question: does every audited route pass axe-core at or above the configured
impact threshold?

## Run it

From the target repo root (a repo carrying `CHANGE.md`):

```
ruby ~/.claude/cf/bin/change_run.rb a11y
```

This boots the app per `boot`, waits for its health signal, stands up one
ephemeral browserless Chromium container (digest-pinned, `--rm`, per
cf:docker; no host browser), injects the vendored, version-pinned axe-core
bundle into each configured route over the browser (never a CDN fetch: a
scanner resolved at scan time cannot be pinned to a report, and a missing
bundle is a named failing finding), grades each violation, tears everything
down, writes the report
pair to `~/Desktop`, and records an `a11y` scope gate under the head SHA. An
`a11y`-scope record never satisfies the comprehensive merge gate; only a full
`cf:change` run does.

This is the platform's version of a prior client's `apps/e2e/src/a11y.ts` scan: same
axe-core-over-browserless approach, but driven by the shared config and reported
through the change-fabric report pair.

## Read the output

Each route reports either "no violations" (pass) or one finding per violation.
A violation at or above the threshold (`lanes.a11y.threshold`, default
`serious`) is a fail; below it is a warn. Each finding carries the rule id,
impact, affected selector, and the Deque help url.

Fix the component, never weaken the scan. If a violation is a genuine false
positive, raise it rather than silently excluding the rule.

A route the browser did not stay on reports `redirected` and fails, naming the
path actually served. Axe ran against that page, not the requested route, so
the route was not audited and the lane will not call it a pass.

## Routes behind a login

Give the lane a `lanes.a11y.auth:` block, the same login flow
`lanes.browserless.auth` takes:

```yaml
lanes:
  a11y:
    routes: ["/login", "/home", "/dashboard"]
    auth:
      login_url: /login
      email_env: CF_A11Y_EMAIL
      password_env: CF_A11Y_PASSWORD
```

Credentials are named, never written: `email_env` and `password_env` hold the
names of environment variables read on the host at run time. The login runs
once in the scan page before the route loop, so every route after it is fetched
with the session's cookies; no per-route opt-in is needed, and a public route
costs nothing. A multi-form login (an OTP flow) uses the explicit `auth.steps:`
list instead, exactly as documented for the browserless lane.

Without the block, every route behind the login redirects to the login page.
Each one then reports `redirected` and fails, rather than reporting the login
page's violations under another route's name.

A login that cannot run (no `login_url`, an unset credential env var) or that
fails in the container reports one `auth login` failing finding naming the
reason, plus one `route not scanned` finding per route. The lane never falls
back to scanning those routes logged out.

## Failure modes

- Docker unavailable, or an image cannot be pulled: exits 2 and names the cause;
  report and stop.
- No `CHANGE.md` with a `change_config:` block: the repo is not change-fabric-integrated. Say so.
- browserless never becomes ready: the lane records a failing finding rather
  than crashing the run.
