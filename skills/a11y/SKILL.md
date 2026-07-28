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
cf:docker; no host browser), injects axe-core into each configured route over
the browser, grades each violation, tears everything down, writes the report
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

## Failure modes

- Docker unavailable, or an image cannot be pulled: exits 2 and names the cause;
  report and stop.
- No `CHANGE.md` with a `change_config:` block: the repo is not change-fabric-integrated. Say so.
- browserless never becomes ready: the lane records a failing finding rather
  than crashing the run.
