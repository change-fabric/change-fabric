# change-fabric platform API

The staging API behind `api.staging.changefabric.org`: Hono on Lambda, Better
Auth with its organization plugin for accounts and teams, Drizzle over Postgres.
It is deployed by `platform/infra`, which zips `dist/` into two functions.

## Layout

```
src/auth-options.ts   Better Auth configuration, plugins, slug immutability
src/app.ts            the Hono app: /healthz, /api/auth/*, /v1/onboarding
src/basic-auth.ts     the staging-wide Basic Auth gate
src/config.ts         environment plus the SSM reads, cached at cold start
src/email.ts          SES v2 sender
src/db/schema.ts      Drizzle mirror of every Better Auth table
src/index.ts          Lambda handler for the API
src/migrate.ts        Lambda handler for migrations and one-off read-only checks
drizzle/              generated migration SQL, applied by the migrate Lambda
```

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

Nothing else lives here yet. `team_api_key`, `repo_link`, `artifact`,
`artifact_file` and `contributor_alias` belong to phases 4, 5 and 6.
