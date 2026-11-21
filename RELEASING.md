# Releasing

Merging to `main` stages work. Nothing is released until you push the matching
tag.

That is the whole rule. A merge to `main` never creates a GitHub Release and
never deploys the production site. Five independent tracks live in this repo,
each with its own tag namespace and its own publish workflow, and each is
released on its own schedule by pushing one tag.

| Track | Version source of truth | Tag | What the tag publishes |
| --- | --- | --- | --- |
| Toolkit | the `skills/v*` tags themselves. No file | `skills/vX.Y.Z` | A GitHub Release, and downstream the Homebrew tap formula bump |
| Spec | `ChangeSchema::VERSION` in `scripts/change_schema.rb` | `spec/vX.Y.Z` | A GitHub Release whose body is the `CHANGELOG.md` section for that version, with the spec markdown attached |
| Site | `site/VERSION` | `site/vX.Y.Z` | A production deploy of `www.changefabric.org`. No GitHub Release |
| Platform app | the `app/v*` tags themselves. No file | `app/vX.Y.Z` | A production deploy of `app.changefabric.org` (once that environment exists; not yet provisioned) |
| Image | the `image/v*` tags themselves. No file | `image/vX.Y.Z` | The `browserless-cf` container image on ghcr, built from `docker/browserless-cf` by `release-image.yml`. No GitHub Release |

## Runbook

### I changed the toolkit (`skills/`, `scripts/`, `install.rb`)

There is nothing to edit. The toolkit has no version file; the tag is the
version.

1. Merge your change to `main`. Nothing is released yet, and nothing in the
   tree declares a pending version number.
2. When you want what has accumulated on `main` to go out, look at what the
   last release was and decide the next number yourself:

   ```
   git fetch --tags
   git tag --list 'skills/v*' | sed 's|^skills/v||' \
     | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
   ```

3. From an up to date `main`, tag it, get Patrick's phone approval, and push.
   The agent runs this; nothing is typed in a terminal:

   ```
   git tag -a skills/vX.Y.Z -m skills/vX.Y.Z
   ruby scripts/approval_console.rb request --type release --tag skills/vX.Y.Z --sha "$(git rev-parse HEAD)"
   # Patrick approves on the phone; then record it and push
   ruby scripts/approval_console.rb record <request_id>
   git push origin skills/vX.Y.Z
   ```

   `change_tag_guard.rb` refuses the push without a release approval for this
   exact tag and commit, under 24h old, and without a passing cf:change run.
   The same applies to the `spec/v*`, `site/v*` and `app/v*` tags below.

   `release-skills.yml` rejects the tag unless it is plain `MAJOR.MINOR.PATCH`,
   newly created rather than moved, and strictly greater than every existing
   `skills/v*` tag. It then publishes a GitHub Release whose notes cover exactly
   the commits since the previous toolkit tag. The same tag drives the
   Homebrew tap with no PR: `bump-tap-formula.yml` rewrites, builds, and tests
   the formula, then pushes it to the tap's main. `tap-drift.yml` fails daily
   and keeps an issue open while the tap trails the newest tag. The tag push is
   the only step; there is no manual script.

A toolkit tag releases everything on `main` at that commit, so pick the number
from what actually landed since the last one: a new skill or hook is a minor, a
fix to an existing one is a patch.

To find out what version a checkout corresponds to, ask git rather than the
tree:

```
git describe --tags --match 'skills/v*'
```

### I changed the spec (a `CHANGE.md` frontmatter field)

1. In one PR: bump `ChangeSchema::VERSION`, update the `Schema version` line and
   the field tables in `skills/change/reference/CHANGE-frontmatter-spec.md`,
   freeze the outgoing version into `site/src/archive/<old>.md` and add it to
   `VERSIONS` in `site/src/spec.ts`, add a `## [X.Y.Z]` section to the root
   `CHANGELOG.md`, and add a `site/src/releaseNotes.ts` entry if the version has
   something to say to a human. The drift test
   (`test/change_schema_spec_test.rb`) fails if the doc and the code disagree.
2. Merge to `main`. Nothing is released yet.
3. Cut the release:

   ```
   git tag -a spec/vX.Y.Z -m spec/vX.Y.Z
   git push origin spec/vX.Y.Z
   ```

   `release-spec.yml` refuses the tag unless `X.Y.Z` matches
   `ChangeSchema::VERSION`, the spec doc's `Schema version` line, and a
   `## [X.Y.Z]` section in `CHANGELOG.md`, all at the tagged commit. It then
   publishes a GitHub Release carrying that changelog section as its body and
   the spec markdown as an asset.
4. The live site does not change yet. Deploy it separately, below, when you
   want `www.changefabric.org/spec` to show the new version.

### I changed the site (`site/`)

1. Bump `site/VERSION` in your PR.
2. Merge to `main`. Nothing is deployed yet.
3. Deploy:

   ```
   git tag -a "site/v$(tr -d '[:space:]' < site/VERSION)" -m "site/v$(tr -d '[:space:]' < site/VERSION)"
   git push origin "site/v$(tr -d '[:space:]' < site/VERSION)"
   ```

   `deploy-site.yml` checks the tag against `site/VERSION`, checks that the spec
   version this build would publish as current has already been released as a
   `spec/v*` tag, then builds and publishes to S3 and CloudFront.

A site tag deploys everything sitting on `main` at that commit, not only your
own change. Tag from a `main` you are willing to ship whole.

### I changed the platform app (`platform/web`, `platform/api`)

Staging deploys continuously: every merge to `main` ships to
`app.staging.changefabric.org` through `deploy-app-staging.yml`, a sibling
mechanism to this document, not something you trigger yourself.

A production release is a separate, deliberate act, and it needs the
production environment to exist first. There is nothing to edit; like the
toolkit, the platform app has no version file, so the tag is the version.

1. Merge your change to `main`. It goes to staging. Nothing goes to production
   yet.
2. Once `app.changefabric.org` and its AWS role are provisioned, when you want
   what has accumulated on `main` to go out, look at what the last release was
   and decide the next number yourself:

   ```
   git fetch --tags
   git tag --list 'app/v*' | sed 's|^app/v||' \
     | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
   ```

3. From an up to date `main`, tag and push it:

   ```
   git tag -a app/vX.Y.Z -m app/vX.Y.Z
   git push origin app/vX.Y.Z
   ```

   `deploy-app-prod.yml` rejects the tag unless it is plain `MAJOR.MINOR.PATCH`,
   newly created rather than moved, and strictly greater than every existing
   `app/v*` tag. It then builds `platform/web` and publishes it to production.

### I changed the browserless-cf image (`docker/browserless-cf`)

The image is the upstream browserless Chromium image plus the OFL faces in
`docker/browserless-cf/fonts.lock`. Only CI builds and publishes it. Two pins
in `scripts/change_docker.rb` keep its two roles apart: `BROWSERLESS_UPSTREAM`
is the third-party digest and only the Dockerfile `FROM` (a test holds them
equal), and `BROWSERLESS_IMAGE` is the runtime pin every capture, diagram,
and lint lane runs.

1. Merge your change to `main`. Nothing is built or published yet.
2. Pick the next number from the existing tags:

   ```
   git fetch --tags
   git tag --list 'image/v*' | sed 's|^image/v||' \
     | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
   ```

3. From an up to date `main`, tag and push it:

   ```
   git tag -a image/vX.Y.Z -m image/vX.Y.Z
   git push origin image/vX.Y.Z
   ```

   `release-image.yml` rejects the tag unless it is plain `MAJOR.MINOR.PATCH`,
   newly created, and strictly above every existing `image/v*` tag, then
   builds and pushes `ghcr.io/<owner>/browserless-cf:X.Y.Z` and prints the
   digest in the job summary.
4. Open a follow-up PR that sets `BROWSERLESS_IMAGE` to the printed
   `image:version@sha256:digest`. Until it merges, runtime stays on upstream.
   A new ghcr package starts private: make it public (or accept that
   consumers need `docker login ghcr.io`) before that PR lands.

Refresh upstream: bump `BROWSERLESS_UPSTREAM` and the Dockerfile `FROM`
together in one PR, merge, push the next `image/v*`, then move
`BROWSERLESS_IMAGE` in a follow-up. Rollback: revert `BROWSERLESS_IMAGE` to
the previous published digest; published digests are never deleted from
ghcr.

## Team setup

Human runbook for the opt-in telemetry, presence, and secret-alert
capabilities, and for publishing `cf:change` findings. Every capability is off
until its env var is set: `CF_TELEMETRY=1` (SessionEnd transcript upload),
`CF_PRESENCE=1` (PreToolUse edit-collision probe), `CF_SECRET_ALERTS=1`
(SessionStart secret-alert poll).

1. Founder, once per team: `ruby scripts/cf_team_init.rb <team_id> "<label>"`
   mints an Ed25519 keypair, registers the public key in the `cf-teams` table,
   and prints a `contributors_team:` block to paste into `CHANGE.md`. Store the
   printed private key in a shared vault yourself; the script never does.
2. Each teammate, once: pipe the private key from the vault into
   `ruby scripts/cf_team_join.rb <team_id> <contributor-id> --stdin`. It caches
   the key in the login Keychain and records the contributor id under
   `~/.claude/cf/teams/<team_id>/`.
3. Publishing findings (optional): add `organization`, `team`, and a
   `platform:` block (`api_url`, `api_key_env`) to `contributors_team:`, then
   cache the team API key with `cf_team_join.rb --platform <org> <team> --stdin`.
   A team that already has a `team_id` runs `cf_team_migrate.rb --dry-run`
   first, then without the flag. The legacy `artifacts:` block is removed at
   schema 0.7.0. Publishing is best effort and never changes a sweep verdict.
4. Telemetry only: put the shared API secret in
   `~/.claude/cf/telemetry/api-secret`; without it the upload is skipped.
5. Homebrew tap publishing: `bump-tap-formula.yml` pushes to
   `change-fabric/homebrew-cf` over SSH with the `TAP_DEPLOY_KEY` repository
   secret, a private ed25519 key whose public half is a write-enabled deploy key
   on the tap repo. Without the secret the job skips. `TAP_BUMP_TOKEN` (a
   personal access token that kept expiring) is removed; delete it if still set.

The hooks fail open when the `ed25519` gem is missing. The three `cf_team_*`
scripts are human-run tools, not hooks, and raise on a missing credential.

## Operational notes

The site deploy assumes an AWS role through GitHub OIDC. That role's trust
policy (`site/infra/oidc.tf`) matches the workflow's `sub` claim, which changed
from `ref:refs/heads/main` to `ref:refs/tags/site/v*` when the trigger changed.
`terraform apply` in `site/infra` has to run once before the first tag deploy
can authenticate.

The spec is at 0.6.0 with no tag behind it, so the first `site/v*` push will
fail its spec guard until `spec/v0.6.0` is cut. Cutting it is the intended
bootstrap step, not a workaround.

## Approved scripts and break-glass

Any script Patrick would otherwise run by hand (a release, a console redeploy,
a queued `~/.claude/cf/manual/queue/` script) is a phone-approved `run-script`:

```
ruby scripts/approval_console.rb request --type run-script --script <queued-script> --title "<what it does>" [--account <12-digit id>]
ruby scripts/approval_console.rb record <request_id>
ruby scripts/cf_run_approved.rb <queued-script>
```

The phone shows the whole script text, the commit and the AWS account. The
runner refuses unless the script on disk hashes to the approved text, this
checkout is on the approved commit, the receipt is under 15 minutes old and
unused, and the current AWS account matches. It consumes the receipt on the
console and in a local ledger, runs the script with no tty, then moves it to
`queue/done/`. The hooks deny running a queued script any other way. Execution
is local only.

Break-glass: a console redeploy changes the console that approves, so it keeps
a manual path. `approval_console/infra/redeploy.sh <sha>` and the other
queued scripts need no console and no receipt: Patrick runs them from a real
terminal. If a run-script redeploys the console and the console is then down,
run `redeploy.sh` (or the previous good commit) by hand the same way. The
runner fails closed while the console is unreachable, so nothing queued runs
through it until the console is back.
