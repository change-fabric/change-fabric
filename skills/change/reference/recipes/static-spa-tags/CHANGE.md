---
spec_version: 0.12.0
change_config:
  project: acme-spa
  default_profile: local
  boot:
    # `serve` runs in the foreground, so it self-detaches with a pidfile.
    up: "npm ci && npm run build && (nohup npx --yes serve -s dist -l 4173 >/tmp/acme-spa.log 2>&1 & echo $! >/tmp/acme-spa.pid)"
    down: "kill \"$(cat /tmp/acme-spa.pid)\" 2>/dev/null; rm -f /tmp/acme-spa.pid"
    target_url: http://host.docker.internal:4173
    health: { url: http://localhost:4173/, expect_status: 200, timeout_seconds: 90 }
  lanes:
    k6: { enabled: false }   # static files on a CDN, no load surface worth gating
    a11y: { enabled: true, routes: ["/", "/about", "/pricing"], threshold: serious }
    # Relative targets resolve against each profile's target_url.
    zap: { enabled: true, targets: ["/"], strict: false }
    browserless:
      enabled: true
      routes: ["/", "/about", "/pricing"]
      viewports:
        - { name: mobile, width: 390, height: 844 }
        - { name: tablet, width: 768, height: 1024 }
        - { name: desktop, width: 1440, height: 900 }
  profiles:
    local: {}
    # Deployed environments are already running: boot is a no-op there.
    staging:
      boot:
        up: "true"
        down: "true"
        target_url: https://staging.spa.example.com
        health: { url: https://staging.spa.example.com/ }
    production:
      boot:
        up: "true"
        down: "true"
        target_url: https://spa.example.com
        health: { url: https://spa.example.com/ }
change_policy:
  protected_refs: [main, "tag:staging/v*", "tag:production/v*"]
  promotion:
    main: { review_required: true, self_review_allowed: true, require_change_pass: true, profile: local }
    "tag:staging/v*": { environment: staging, require_change_pass: true, profile: staging, require_trunk_ancestor: main }
    "tag:production/v*": { environment: production, require_change_pass: true, profile: production, require_trunk_ancestor: main, require_prior_tag: "staging/v*", review_required: true, self_review_allowed: false }
  admin_bypass: { allowed: false, require_change_pass: true }
---

# Change management for acme-spa

For a static single-page app built to `dist/` and served from a CDN, with one
long-lived branch, `main`, and releases cut as tags instead of environment
branches.

## How a change reaches production

1. A PR lands on `main` after review, CI, and a passing `cf:change` run
   under the `local` profile, which builds the app and serves `dist/` on
   port 4173.
2. Tag the same commit `staging/v1.4.0`. Publishing that tag is denied until
   `cf:change` has passed for that commit under the `staging` profile, which
   audits the deployed staging site rather than booting anything.
3. Tag it `production/v1.4.0`. The commit must already be on `main` and
   already carry a `staging/v*` tag, and the production audit must pass.
   Production needs a reviewer other than the author.

Sweep the exact commit being tagged before publishing the tag:

```bash
ruby ~/.claude/cf/bin/change_run.rb all --for-tag staging/v1.4.0
```

## Why these lanes

k6 is off: a static bundle on a CDN has no server-side load surface this
repo owns. Accessibility, responsive layout, and the passive ZAP baseline run
everywhere, because a broken build or a missing security header shows up in
the served files, not in the source.
