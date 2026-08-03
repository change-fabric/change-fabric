# change-fabric platform API

The staging API behind `api.staging.changefabric.org`: Hono on Lambda, Better
Auth with its organization plugin for accounts and teams, Drizzle over Postgres.
It is deployed by `platform/infra`, which zips `dist/` into two functions.

## Layout

```
src/auth-options.ts   Better Auth configuration, plugins, slug immutability
src/app.ts            the Hono app: route registration and the one error handler
src/basic-auth.ts     the staging-wide Basic Auth gate
src/config.ts         environment plus the SSM reads, cached at cold start
src/email.ts          SMTP sender (staging, Mailpit) and SES v2 sender
src/validation.ts     reading a request body without trusting any of it
src/api-keys.ts       minting, hashing, and recognising a team API key
src/store.ts          the platform's own tables, as an interface plus Drizzle
src/routes/context.ts who is calling, and what they may do
src/routes/*.ts       teams, keys, invitations, repo links, contributor aliases
src/db/schema.ts      Drizzle mirror of every Better Auth table, plus our own
src/index.ts          Lambda handler for the API
src/migrate.ts        Lambda handler for migrations and one-off read-only checks
drizzle/              generated migration SQL, applied by the migrate Lambda
```

## Routes

| Route | Who |
| --- | --- |
| `POST /v1/onboarding` | any session with no organization |
| `GET /v1/teams`, `GET /v1/repos` | any member |
| `GET /v1/teams/:id/members`, `GET /v1/teams/:id/keys` | any member |
| `POST /v1/teams`, `PATCH /v1/teams/:id`, `POST /v1/teams/:id/archive` | owner or admin |
| `POST`/`DELETE /v1/teams/:id/members/...` | owner or admin |
| `POST /v1/teams/:id/keys`, `.../keys/:keyId/revoke` | owner or admin |
| `POST`/`GET /v1/invitations`, `POST /v1/invitations/:id/accept` | owner or admin, except accept |
| `POST`/`DELETE /v1/repos` | owner or admin |
| `GET /v1/teams/:id/aliases` | any member |
| `POST /v1/teams/:id/aliases` | owner or admin |
| `GET /v1/whoami-key` | a team API key, no session |

Every write to a Better Auth table goes through `auth.api` rather than the
database, so the plugin's permissions, hooks and cascades all fire. The one read
that does not is `store.listTeamMembers`: the plugin's own `list-team-members`
refuses a caller who is not on that team, which is exactly the person a team
detail page is for.

## Working on it

```
npm ci
npm run typecheck
npm test
npm run build          # dist/index.mjs, dist/migrate.mjs, dist/drizzle
```

After changing `src/db/schema.ts`:

```
npm run db:generate
```

`drizzle-kit generate` needs no database connection, which matters because the
instance is only reachable from inside the VPC. The generated SQL is applied by
invoking `cf-platform-migrate`; see `platform/infra/README.md`.

## Two layers of auth, in order

1. **HTTP Basic Auth**, from `/cf-platform/staging/basic-auth-credential`. A
   coarse fence keeping staging off the open internet, applied to everything
   except `/healthz`. Compared with `crypto.timingSafeEqual`.
2. **Better Auth sessions and organization membership.** The real thing. Cookies
   are scoped to `.staging.changefabric.org` so a session set by the API host is
   readable by the web app host in phase 3, and are `Secure`, `HttpOnly`,
   `SameSite=Lax`.

Both apply. Neither substitutes for the other.

## Where transactional mail goes

`src/email.ts` carries two senders and picks between them on one fact: whether
`SMTP_HOST` and `SMTP_PORT` are set.

| Set | Path | Where |
| --- | --- | --- |
| yes | SMTP, via nodemailer | Mailpit, on staging. `https://mailpit.staging.changefabric.org` |
| no | the SES v2 API | wherever SES delivers, which is production's path |

Staging **replaces** SES rather than sending both ways, and the reason is that
SES is in the sandbox on this account: every send to an address that is not a
pre-verified identity is rejected. Sending both ways would put a guaranteed
rejection in the log beside every successful delivery, which teaches a reader to
skip the one line that would matter if the SES path ever broke for a real
reason. The SES sender is untouched, still covered, and still exercised directly
by `migrate.ts`'s `sesCheck` action against the mailbox simulator.

What decides is deliberately the presence of somewhere to submit mail, not an
environment name. Terraform already knows whether a Mailpit exists in a given
deployment and already sets these two variables; an `ENVIRONMENT=staging` string
would be a second claim about the same thing, and the day the two disagreed the
mail would go somewhere nobody expected.

Either way the send is wrapped in `bestEffort`. A mail is a side effect of
creating an account or an invitation, not part of it, and a Mailpit task that is
restarting must no more roll back a sign-up than a sandboxed SES did.

## Onboarding is explicit

Signing up does not create an organization. `POST /v1/onboarding` does, taking
`{ organizationName, organizationSlug }` from the sign-up form and calling the
organization plugin's own create path, so the owner membership and every hook
fire exactly as they would for any other caller.

The slug is taken, never derived. A slug derived from a name would quietly be a
different handle than the one someone typed, and slugs are immutable.

## Slugs are immutable

An organization slug and a team slug cannot be changed after creation. Both are
public handles that end up in URLs and in whatever a downstream repository has
already recorded, so renaming one breaks references rather than following them.

Enforcement is a pair of Better Auth hooks (`beforeUpdateOrganization`,
`beforeUpdateTeam`) that reject any update payload carrying a `slug` key at all,
including one that repeats the current value: there is no code path where a slug
write reaches the database. Renaming the display `name` is unaffected.

## Schema

Better Auth's four core tables (`user`, `session`, `account`, `verification`)
and the organization plugin's five (`organization`, `member`, `team`,
`team_member`, `invitation`). `team` carries three platform additions declared
through `schema.team.additionalFields`, so the plugin reads and writes them too:

| Column | Shape | Why |
| --- | --- | --- |
| `slug` | text, not null | The team's handle, unique within its organization. |
| `public_key_ed25519` | text, nullable | Signing key for a team's own artifacts, filled in by a later phase. |
| `legacy_team_id` | text, nullable, unique | The identifier a team had before it was hosted, so the same one cannot be claimed twice. |

`(organization_id, slug)` is unique: two organizations may each have a `core`
team, and neither should block the other.

The plugin's default-team-on-create is disabled, because a default team would be
created with no slug and slug is required.

`team` also carries `archived_at`. Archiving is a soft delete: a team's slug is
already in artifact paths and in whatever a downstream repository recorded, and
its keys and repo links point at it, so removing the row would strand references
rather than retire them.

## The two tables Better Auth does not own

`team_api_key` and `repo_link`. Both cascade from `organization`, so a deleted
organization takes them with it.

**`team_api_key`** stores only the SHA-256 digest of a key, never the key. The
raw value is returned by exactly one response, `POST /v1/teams/:id/keys`, and is
not recoverable afterwards even by the API itself. `key_prefix` exists so a
person can tell two of their own keys apart later; it is the scheme, the
organization slug, and six characters of the random segment, which is a strict
non-secret prefix of the raw value.

The key format is `cfp_<org-slug>_<32 random bytes, base64url>`. Note that the
base64url alphabet contains an underscore, so the separator before the secret is
the SECOND underscore from the front, never the last one. Deriving the prefix
from the last underscore publishes nearly the whole key; `test/api-keys.test.ts`
holds a property test against exactly that.

**`repo_link`** claims a repository for a team. `repo_id` is the normalized
`host/path` form of a git remote (`github.com/acme/web`), not a URL, because the
same repository is reachable over SSH and HTTPS with different spellings and a
claim has to survive all of them. It is unique across the whole table rather than
per organization, because the question it answers is "which team owns what this
run pushed from" and two organizations claiming one repository has no consistent
answer.

**`artifact`** and **`artifact_file`** are one published findings run and the
files it declared. The row is the record; S3 is only storage.

`key_prefix` is written at creation as `<org-slug>/<team-slug>/<short-id>/` and
every presigned URL and every CloudFront signed cookie is scoped to it, so
authorization is a question about the row rather than about a bucket listing.
Nothing derives the prefix a second time from parts that could have changed.

`short_id` is ten Crockford base32 characters, unique per **team** rather than
globally, matching the team slug rule: a short id only ever appears inside a path
that already names the team. `id` is a ULID, so descending id is descending
creation time and the listing route's cursor can be the last id seen rather than
an offset that shifts under a concurrent insert.

`published_at` stays null until `POST /v1/artifacts/:id/complete`. A row with a
`generated_at` and no `published_at` is a run that was announced and abandoned,
which is a real state worth seeing rather than one to paper over.

`contributor_user_id` and `contributor_label` are both nullable and both present
because a run may come from a person (a session) or from a machine (a team API
key, which belongs to a team and to nobody). Folding them into one column would
mean losing the foreign key or storing a user id that names nobody.

`repo_id` is nullable in this phase. Phase 6 is what knows which repository a run
came from; recording a value now would be recording a guess.

## The artifacts routes

| Route | Who | What |
| --- | --- | --- |
| `POST /v1/artifacts` | session on the team, or `x-cf-key` scoped to it | Creates the rows and returns one presigned `PUT` per file, 15 minutes. |
| `POST /v1/artifacts/:id/complete` | same | Sets `published_at`. Compares stored objects against the manifest and records a note; a mismatch never fails the run. |
| `GET /v1/artifacts?teamId=` | any organization member | Keyset page, newest first. |
| `GET /v1/artifacts/authorize?teamId=` | session with a `team_member` row | Mints CloudFront signed cookies as three `Set-Cookie` headers. |
| `GET /v1/artifacts/:shortId/download` | `x-cf-key` only | Presigned `GET` per file. No cookies involved. |

Bytes never pass through this function in either direction. A presigned URL
carries the SIGNER's authority, not the caller's, which is why the Lambda role
holds real `s3:PutObject`/`s3:GetObject` on the one bucket and `kms:GenerateDataKey`
on the platform CMK: the browser or CI job that follows a URL is anonymous to S3.

The bucket's default encryption is SSE-KMS and nothing in `storage.ts` names the
key. A presigned `PUT` carrying explicit encryption parameters would oblige the
uploader to send matching headers and turn any mismatch into a 403 they could do
nothing about; letting the bucket default apply encrypts the object identically
with one fewer thing to get wrong.

`GET /v1/artifacts/authorize` is the only route that answers with `Set-Cookie`,
and the cookies are not this application's. CloudFront verifies them at the edge
against a trusted key group, so this route's own correctness is not the last line
of defence: a forged cookie fails at CloudFront regardless of what it decided.
The scope is a team's whole prefix for eight hours, not one artifact, because the
question it answers does not change between two runs of the same team.

## `contributor_alias`: who somebody was before this platform

A repository's `CHANGE.md` carries a self-asserted roster of `{id, name}` pairs,
and every findings run published before this service existed is attributed to
one of those ids. `contributor_alias` is how such an id keeps meaning something:
it maps a legacy `contributors[].id` to the team it belonged to, the display
name it was registered under, and the account behind it when there is one.

| Column | Shape | Why |
| --- | --- | --- |
| `team_id` | text, not null, cascade | The alias belongs to a team, not to an organization: rosters are per team. |
| `legacy_contributor_id` | text, not null | The old `contributors[].id`, e.g. `pst`. |
| `display_name` | text, not null | The old `contributors[].name`. What historical attribution renders as. |
| `user_id` | text, nullable, `on delete set null` | The account, once there is one. |

`(team_id, legacy_contributor_id)` is unique, because a roster id names one
person within one team. It is deliberately NOT unique globally: two unrelated
teams may each have a contributor called `pst`.

**`user_id` being nullable is the design, not an omission.** A roster names
people who may never sign in, and refusing to record them until they do would
make their history read as nobody's. Null means "no account here yet", which is
a fact worth storing. `on delete set null` keeps the alias, and therefore the
attribution, when an account is removed.

`POST /v1/teams/:id/aliases` never takes a `userId` from the body. A caller
naming a user id would be asserting that somebody else's account is the same
person as a roster entry, which is exactly the claim that must not be
self-served. It accepts an `email` instead and links only when an account with
that address exists **and has verified it**; an unverified address is something
somebody typed at sign-up, not a proof. The route is idempotent: a second call
for a mapped legacy id answers 200 with the existing row rather than 201, which
is what lets `scripts/cf_team_migrate.rb` be re-run safely.

`POST /v1/teams` accepts optional `legacyTeamId` and `publicKeyEd25519`, and
`GET /v1/teams` returns both. They are written in the same statement that
creates the team because `legacy_team_id` is unique, so claiming a legacy team
is one atomic decision rather than a two-step one that can be lost halfway. A
legacy id another team already holds answers 409 rather than surfacing a unique
violation as a 500; the check reports only that the id is taken, never which
team took it, because that team may be in an organization the caller cannot see.
