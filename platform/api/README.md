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
src/email.ts          SES v2 sender
src/validation.ts     reading a request body without trusting any of it
src/api-keys.ts       minting, hashing, and recognising a team API key
src/store.ts          the platform's own tables, as an interface plus Drizzle
src/routes/context.ts who is calling, and what they may do
src/routes/*.ts       teams, keys, invitations, repo links
src/db/schema.ts      Drizzle mirror of every Better Auth table, plus our own two
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

`artifact`, `artifact_file` and `contributor_alias` belong to phases 5 and 6.
