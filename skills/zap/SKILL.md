---
name: pst:zap
description: Runs just the OWASP ZAP penetration-test lane of the change-fabric platform against a project's config. Runs the digest-pinned ZAP baseline (passive spider and passive checks, no attack traffic) as an ephemeral container against each in-scope target, turns every alert into a finding, and writes a CSV and Markdown report to the Desktop. Invocable directly for a standalone security check.
---

# PST ZAP

The standalone OWASP ZAP penetration-test lane of the change-fabric platform.
Runs only the security audit; for the full four-lane release sweep use
`pst:change`. This lane is net-new to the platform: no ZAP automation existed in
the source repos, so the platform defines the contract.

Trigger: `/pst:zap [<target>]`.

Question: does each in-scope target pass a passive ZAP baseline without a
high-risk alert (or, in strict mode, any alert)?

## Run it

From the target repo root (a repo carrying `CHANGE.md`):

```
ruby ~/.claude/pst/bin/change_run.rb zap
```

This boots the app per `boot`, waits for its health signal, runs the ZAP image's
baseline automation (digest-pinned, `--rm`, per pst:docker) against each url in
`lanes.zap.targets` on the run network, tears the app down, writes the report
pair to `~/Desktop`, and records a `zap` scope gate under the head SHA. A
`zap`-scope record never satisfies the comprehensive merge gate; only a full
`pst:change` run does.

The baseline is passive: it spiders the target and runs passive checks (security
headers, cookie flags, information leakage, known-vulnerable libraries). It sends
no attack traffic, so it is safe against a local stack.

## Gate policy

This lane sets its own release-gate bar rather than mirroring ZAP's WARN/FAIL
exit convention:

- A high-risk alert fails the lane.
- With `lanes.zap.strict: true`, any low-risk-or-above alert fails.
- Everything below the fail bar is a warn and still appears in the report.

Each alert becomes one finding with its ZAP risk level, the affected url, and a
reference link.

## Common findings

Most first-run alerts on a young app are missing-header warnings: Content
Security Policy not set, missing X-Frame-Options / anti-clickjacking, missing
X-Content-Type-Options nosniff, cookies without Secure/HttpOnly/SameSite, and
server version leakage. Fix the header or config at its source (the app,
the auth library, or the edge), then re-run. Do not silence an alert without
fixing or consciously accepting it.

## Failure modes

- Docker unavailable, or the ZAP image cannot be pulled: exits 2 and names the
  cause; report and stop.
- No `CHANGE.md` with a `change_config:` block: the repo is not change-fabric-integrated. Say so.
- ZAP internal error (its exit code 3): reported as a failing finding for that
  target rather than a silent pass.
