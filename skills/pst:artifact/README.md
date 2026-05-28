# `/pst:artifact` - the planning artifacts studio

A private, self-hosted "Claude Artifacts" for plans. Turn a plan into a
**bespoke, interactive web artifact** - composed from a component kit, given its
own art direction, reviewed with **click-anywhere comments**, and published to a
**no-index subdomain** with one command.

```
skills/pst:artifact/
  SKILL.md                      # the slash-command instructions
  studio/                       # the Astro app (the "studio")
    src/components/kit/         # the block vocabulary you author with
    src/content/plans/<id>.mdx  # one bespoke artifact per file (filename = id)
    src/pages/p/[id].astro      # routes each artifact to /p/<id>/
    src/components/comments/    # dev-only click-anywhere comment layer
    src/middleware.ts           # dev-only on-disk comment round-trip
    feedback/<id>.json          # captured comments (git-ignored)
  scripts/
    plan_id.py                  # collision-checked short id + slug generator
    publish.py                  # build → s3 sync → CloudFront invalidation
  terraform/                    # S3 + CloudFront + ACM + Route53 (+ opt-in analytics)
  plans.config.example.json     # copy → plans.config.json (git-ignored)
```

## How it works

- **Author** - `/pst:artifact` writes `studio/src/content/plans/<id>.mdx` (the
  filename is a stable short id) and runs `astro dev`. The page is composed from
  `@kit` blocks with a per-plan theme, so it looks bespoke, not templated.
- **Review** - open the page, click **Comment**, drop pins anywhere. Each pin
  captures the nearest anchor, section, a CSS selector, and the local text, then
  persists to `studio/feedback/<id>.json` via a dev-only middleware endpoint.
- **Revise** - `/pst:artifact --feedback <id>` reads those threads back and edits the
  artifact. A real round-trip, not a clipboard paste.
- **Publish** - `/pst:artifact --publish <id>` runs the WCAG contrast gate, builds the
  static site, syncs to S3, and invalidates CloudFront. URLs are Amazon-style:
  `/p/<id>/<slug>` where the short **id is canonical** and the **slug is cosmetic**
  (a CloudFront function strips it, so typos and renames still resolve). Pages are
  **no-index** by default.
- **Iterate** - pass an existing id or URL from _any_ session
  (`/pst:artifact <id> "tighten the hero"`); publish stashes the MDX source in S3, so
  it's fetched, edited, and re-published **under the same id/URL**.
- **Self-destruct (TTL)** - published artifacts carry an `expires-at` tag and a
  daily reaper (on by default) **deletes expired ones outright from S3**. Default
  lifetime **7 days**; `--ttl 30d` / `--ttl never` to change. `--destroy <id>`
  removes one immediately.

### Accessibility

`studio/src/a11y.test.ts` is a deterministic WCAG AA contrast gate over the theme
palette; `publish.py` runs it before every build, so a contrast regression blocks
publishing. For deep DOM audits, run an axe pass (e.g. `/REDACTED:accessibility`)
against the dev server.

## Bring your own domain + AWS account

Convention over configuration - it should just work:

1. **Provision once** (BYO AWS account + a Route53 hosted zone for your apex
   domain):
   ```bash
   cd terraform
   cp terraform.tfvars.example terraform.tfvars   # set domain, hosted_zone_name, aws_profile
   terraform init && terraform apply               # CloudFront + ACM ~15–30 min
   ```
2. **Configure** the studio:
   ```bash
   cp plans.config.example.json plans.config.json  # set domain + awsProfile
   ```
   The S3 bucket name defaults to the domain and the CloudFront distribution is
   discovered by its alias - **no infra IDs in config.**
3. **Publish:** `/pst:artifact --publish <id>`.

Without `plans.config.json` the studio is fully usable **locally** - publishing
just stays dark until you opt in.

### Optional: view counts

A privacy-light per-artifact view counter is available and **off by default**.
Set `enable_analytics = true` in `terraform.tfvars`, `terraform apply`, then copy
the `analytics_endpoint` output into `plans.config.json` as `analyticsEndpoint`.
Published pages then show a view count. It stores only an incrementing integer
per id - no PII, no IP logging. See `terraform/analytics.README.md`.

## Requirements

- Node 20+ (the studio is Astro 5)
- For publishing: Terraform ≥ 1.5, the `aws` CLI, an AWS profile, and a Route53
  public hosted zone for your apex domain.
