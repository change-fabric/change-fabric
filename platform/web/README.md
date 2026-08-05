# change-fabric platform web app

The staging web app behind `app.staging.changefabric.org`: Vite, React and
TypeScript, talking to the phase 2 API through Better Auth's client and the
organization plugin. It is deployed by `platform/infra` (S3, CloudFront, Route53)
and published by `deploy.sh`.

It is a separate deployable from `site/`. `site/` is a hard-cached marketing page
with its own release cadence; this is an authenticated shell. They share the
brand tokens (copied, not imported) so the two read as one product, and share
nothing else.

## Layout

```
src/config.ts           where API calls go, and why they go there
src/auth.ts             the one Better Auth client, organization plugin loaded
src/api.ts              the platform's own routes, and one place that reads a failure
src/router.ts           pushState routing, small enough to read in one sitting
src/App.tsx             account state first, URL second
src/pages/              sign up, log in, onboarding, dashboard, teams, accept-invite
src/components/         the shell, the org switcher, the invite dialog, the notice
basic-auth.function.js  CloudFront Function TEMPLATE, digest substituted at deploy
deploy.sh               publish the function, sync dist/, invalidate
test/                   the pure logic, in node, in under a second
verify/run.mjs          phase 3 headless run: sign-up, onboarding, the dashboard
verify/teams.mjs        phase 4 headless run: teams, invites, membership, keys
verify/artifacts.mjs    phase 5 headless run: publishing, and reading a run back
verify/legacy-migration.mjs  phase 7: a migrated team's findings, as a person sees them
```

## A session that belongs to organizations but has none active

Better Auth sets a session's active organization when that session CREATES one.
It does not set one on sign-in, so any session that is not the creating session
starts with none: signing out and back in, or an organization created for the
account by something else, which is exactly what `scripts/cf_team_migrate.rb`
does.

`App.tsx` sets it. Without that, `getFullOrganization()` returns nothing, the
page falls back to rendering `organizations[0]`, and the result is a screen
naming an organization the SERVER does not consider active: every `/v1` route
reads the session, so the page renders a name and then 400s on its first real
request. The organization switcher would fix it by hand, except that a person
with exactly one organization is never shown a switcher, so there is no manual
path out of it at all.

## Teams, invitations, and keys

The Teams screens are the only ones that load their own data rather than reading
the account state `App.tsx` already fetched. That is deliberate: they are the
screens that write, so they reload after a write instead of waiting for the whole
account to be refetched.

A minted key is shown once, in a banner that says so, and then never again. The
API stores only its digest, so there is nothing to show later even if this page
wanted to. The listing below the banner shows prefixes only.

The create-team, invite and mint-key controls render only for an owner or an
admin. That is a courtesy, not the rule: the API answers 403 to a member either
way, and `verify/teams.mjs` proves it with curl and a real member's session
cookie rather than by observing that a button was hidden.

## Working on it

```
npm ci
npm run typecheck
npm run build          # dist/
npm run dev            # proxies /api and /v1 to the deployed staging API
```

## The app is same-origin with its API

The deployed app calls its own origin. CloudFront forwards `/api/*` and `/v1/*`
to the phase 2 API Gateway custom domain, so `app.staging.changefabric.org/api/auth/...`
reaches the same Lambda that `api.staging.changefabric.org/api/auth/...` does.

That is not a preference. Two things make a direct cross-origin call impossible:

1. **The Basic Auth gate.** Every staging surface sits behind one shared
   credential. A browser replays Basic credentials only to the origin that
   challenged it, so a call from this host to `api.staging` arrives with no
   `Authorization` header and the API's own gate rejects it. The only way to make
   that call succeed would be to ship the staging credential inside the
   JavaScript bundle, which is a worse answer than the question.
2. **CORS preflight.** A cross-origin JSON POST needs an `OPTIONS` preflight,
   and a preflight never carries credentials, so it hits the Basic Auth gate and
   gets a 401. Even past the gate the API answers 404: it registers `GET` and
   `POST` only.

Same-origin removes both at once. The one Basic Auth challenge the browser
answers for this host covers the API calls too, and the session cookie Better
Auth scopes to `.staging.changefabric.org` keeps working exactly as phase 2
configured it. `VITE_API_ORIGIN` overrides the origin for a local run against a
different API.

## Two layers of auth, in order

Same as the API, and for the same reason:

1. **HTTP Basic Auth**, applied at the edge by a CloudFront Function, from
   `/cf-platform/staging/basic-auth-credential`. A coarse fence keeping staging
   off the open internet.
2. **Better Auth sessions and organization membership.** The real thing, in the
   API, underneath the fence.

### Why the edge gate holds a digest and not the credential

A CloudFront Function runs with no network access at all, so it cannot read SSM
per request the way the API's Lambda middleware does. `basic-auth.function.js` is
therefore a **template** carrying two placeholders. `deploy.sh` reads the SSM
parameter, computes the SHA-256 digest of the expected `Authorization` header,
substitutes it, and publishes the result. The compiled function exists only in
AWS: the plaintext credential and its digest are never committed, never written
into a Terraform plan, and never stored in Terraform state (which is why the
distribution reads the function through a data source instead of managing it).

The digest covers the whole header value, so there is one algorithm across the
estate rather than two. It began as the per-team artifact function's convention;
that function is gone now that the artifacts service replaced per-team
provisioning, and this is where the convention lives.

### The same function also does the SPA routing

Once the credential checks out, the function rewrites an extensionless path that
is not `/api/*` or `/v1/*` to `/index.html`, so a deep link or a reload reaches
the client router.

That replaced a distribution-wide `custom_error_response` mapping 403 and 404 to
`/index.html` with a 200. That is the usual recipe for a SPA on S3 behind OAC, and
it cannot work on this distribution, because the same distribution also fronts
the API: the mapping is distribution-wide, so once the API grew routes that
legitimately answer 403 (a member attempting an owner-only write) and 404 (an id
from another organization), every one of those reached the browser as a 200
carrying an HTML page, and `src/api.ts` reported "no readable body" instead of
the reason the server gave. Rewriting in the function is scoped by construction:
an API path is returned untouched, so its status arrives intact.

Rotating the credential:

```
aws ssm put-parameter --region us-east-1 --overwrite \
  --name /cf-platform/staging/basic-auth-credential \
  --type SecureString --value 'user:pass'

npm run build && ./deploy.sh          # republishes the function with the new digest
```

The API picks the new value up on its next cold start; the edge picks it up when
`deploy.sh` republishes.

## Deploying

`deploy-app-staging.yml` runs this on every push to `main` that touches
`platform/web/**`: `npm ci`, `npm run build`, then `deploy.sh` with
`APP_BUCKET`/`APP_DISTRIBUTION_ID` from the `APP_STAGING_BUCKET` and
`APP_STAGING_DISTRIBUTION_ID` repo variables, under a role assumed through
GitHub OIDC (`DEPLOY_APP_STAGING_ROLE_ARN`, trusted for `ref:refs/heads/main`
only, per `platform/infra/webapp.tf`). No local Terraform state access needed
in CI.

To deploy by hand instead:

```
export AWS_PROFILE=personal
npm ci && npm run build
./deploy.sh
```

`deploy.sh` publishes the Basic Auth function first, then syncs `dist/` (hashed
assets immutable for a year, `index.html` on a sixty-second must-revalidate so a
deploy is visible on the next load), then invalidates the distribution. Without
`APP_BUCKET`/`APP_DISTRIBUTION_ID` set, it falls back to reading
`terraform -chdir=../infra output`, which is when `AWS_PROFILE` defaults to
`personal`.

On a **first-ever** provision the order is three steps, because the distribution
references the published function:

```
./deploy.sh                       # creates and publishes the function; skips the sync
terraform -chdir=../infra apply   # builds the distribution around it
./deploy.sh                       # publishes the site
```

Every run after that is one run.

## What CI checks

The `platform-web` job in `.github/workflows/ci.yml` runs `npm ci`, then
`npm run typecheck`, `npm test` and `npm run build`, on every pull request into
`main` or a `platform/**` branch. It carries no `paths:` filter, matching every
other job in that workflow: a required check that silently skips is worse than
one that runs for two minutes on a docs-only change.

`npm test` is Vitest over `test/`, in a node environment, in well under a second.
It covers the parts of this package that are decisions rather than plumbing: how
`src/api.ts` turns a failure into something a person can read, the query and body
shapes the API rejects if they carry an empty value where it expected an absent
one, where `src/config.ts` resolves the API origin, and that `SLUG_PATTERN` is
still character-for-character the pattern `platform/api` enforces. That last one
is the point of the whole file: the mirror exists to save a round trip, and a
mirror that has drifted is worse than no mirror at all.

There is no component render test here. The components are exercised against real
staging by `verify/`, and a jsdom render of a page whose only job is to talk to
the network would assert the mock rather than the app.

## Verifying a deploy

Four runs, each wired to its own script, plus one that runs all four in order:

```
export AWS_PROFILE=personal
npm run verify:all                # signup, teams, artifacts, legacy-migration
npm run verify:signup             # or any one of them on its own
npm run verify:teams
npm run verify:artifacts
npm run verify:legacy-migration
```

Each writes its screenshots to its own directory under `.verification/`, so
`verify:all` ends with all four runs' evidence rather than only the last one's.
`npm run verify` still means the sign-up run, which is what it always meant.

`verify/run.mjs` drives the real deployed site in a real browser and then checks
the rows against Postgres, so a pass is not the UI vouching for itself:

```
export AWS_PROFILE=personal
npm run verify:signup
```

It starts the digest-pinned browserless Chromium container this repo already
standardises on (`scripts/change_docker.rb`), connects Playwright to it over CDP,
and tears it down on any exit path. No host browser is launched.

Each run signs up a fresh `success+cfweb<timestamp>@simulator.amazonses.com`, so
re-running never collides and never needs a human inbox. It covers the Basic Auth
gate, sign-up, the verification notice, onboarding, the dashboard, the members
list, the absence of a switcher for a single-organization account, log out and
log back in, a rejected password, a duplicate email, and finally a
`cf-platform-migrate` `query` confirming the `user`, `member` and `organization`
rows really exist and say what the screen said.

Screenshots land in `.verification/`, which is gitignored: they are evidence for
the run that produced them, not an artifact of the build.

`verify/teams.mjs` is the phase 4 run, on the same harness. It drives TWO browser
contexts side by side, one per person, so an owner and a contributor each hold
their own cookie jar exactly as two people would:

```
export AWS_PROFILE=personal
node verify/teams.mjs
```

Twelve steps: onboard an owner, create two teams, sign up a second account
standalone, invite it onto one team, accept through the real link, add it to the
second team as well, mint a key, resolve that key against `/v1/whoami-key` and
confirm `last_used_at` moved in Postgres, revoke it and confirm the same call
stops working, then prove the member-role 403 with curl and that member's own
session cookie. Every claim is checked against Postgres through the
`cf-platform-migrate` `query` action, not against what the screen said.

The key banner is dismissed BEFORE the keys panel is screenshotted, so no image
in `.verification/` ever carries a raw key.

`verify/artifacts.mjs` is the phase 5 run, on the same harness:

```
export AWS_PROFILE=personal
node verify/artifacts.mjs
```

Almost none of it is a UI test, and deliberately so. The claims that matter are
about an edge nobody can see from inside the app, so they are made with curl
against the live host: that the viewer URL answers 401 without Basic Auth and 302
with it, that the object path answers CloudFront's own 403 without a signed
cookie, that the same cookies lifted out of the browser fetch the fixture from
`artifacts.staging.changefabric.org` outside a browser entirely, that changing one
character of the signature turns that 200 into a 403, that a team API key gets
working presigned GET URLs, and that the bucket is unreachable unsigned. The
browser appears once, for the one claim only a browser can make: that somebody
following a link to a run they have never opened ends up looking at the run.

## The artifacts surface in this app

Two routes, and they do quite different jobs.

`/teams/:teamId/artifacts` lists what a team published. Every row links straight
at the artifacts host rather than proxying anything, because the bytes are served
by CloudFront under a signed cookie and this app's job is only to say which runs
exist.

`/artifacts/authorize` is the one screen nobody chooses to visit. The artifacts
host redirects a browser here when it has no CloudFront cookie yet, carrying
`next` (where they were going) and `team` (a slug, because the edge only ever
sees the path). It resolves the slug through the caller's own team list, asks
`GET /v1/artifacts/authorize` for cookies, and follows `next`.

`next` arrives in a query string, so it is attacker-supplied by construction. It
is followed only after the API has said which prefix it just authorised, and only
if `next` is inside it; anything else is discarded in favour of the team's own
viewer root. That check is the reason the authorize route is not an open
redirect.

It has to be a screen and not a silent effect, because three things can go wrong
and each is something a person has to be told: they are not on that team, the
team is not in the organization they are acting as, or the link was malformed.

## What is not here

Changing somebody's role after they join, and the publish pipeline that calls
`/v1/artifacts` from a contributor's own repository. Those are later phases.
