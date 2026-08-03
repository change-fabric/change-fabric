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
verify/run.mjs          phase 3 headless run: sign-up, onboarding, the dashboard
verify/teams.mjs        phase 4 headless run: teams, invites, membership, keys
```

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

The digest covers the whole header value, matching the existing precedent in
`skills/change/reference/artifact-basic-auth.function.js`, so there is one
algorithm across the estate rather than two.

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

```
export AWS_PROFILE=personal
npm ci && npm run build
./deploy.sh
```

`deploy.sh` publishes the Basic Auth function first, then syncs `dist/` (hashed
assets immutable for a year, `index.html` on a sixty-second must-revalidate so a
deploy is visible on the next load), then invalidates the distribution.

On a **first-ever** provision the order is three steps, because the distribution
references the published function:

```
./deploy.sh                       # creates and publishes the function; skips the sync
terraform -chdir=../infra apply   # builds the distribution around it
./deploy.sh                       # publishes the site
```

Every run after that is one run.

## Verifying a deploy

`verify/run.mjs` drives the real deployed site in a real browser and then checks
the rows against Postgres, so a pass is not the UI vouching for itself:

```
export AWS_PROFILE=personal
node verify/run.mjs
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

## What is not here

Changing somebody's role after they join, and the artifacts surface. Those are
later phases.
