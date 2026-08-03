# change-fabric team setup (Capabilities A, B, C)

This is the human runbook for the AWS-backed change-fabric telemetry, presence,
and secret-alert system. All three capabilities are OFF by default and gated
behind per-capability `CF_*` env vars, so nothing here runs until you opt in.

## One time per team (the founder)

Run `cf_team_init.rb` once to mint the team keypair and register the team:

```
ruby scripts/cf_team_init.rb <team_id> "<label>"
```

It will:

1. Generate a fresh Ed25519 keypair.
2. `PutItem` the team's PUBLIC key into the `cf-teams` DynamoDB table
   (region `us-east-1`, AWS profile `personal`, override with `AWS_PROFILE`).
3. Print a ready-to-paste `contributors_team:` YAML block. Paste it into the
   repo's `CHANGE.md` frontmatter and fill in the `contributors:` list with a
   stable `id` and display `name` per teammate. Commit it.
4. Print a suggested `op item create` command (using the local 1Password wrapper
   at `~/code/pst/pstaylor-patrick/secrets/bin/op`) for storing the PRIVATE key
   in a shared vault. Review and run it yourself. The script never executes it.

The private key is base64 of the 32-byte Ed25519 seed. It is a team-level shared
secret. The public key is safe to commit (verify-only).

## One time per teammate (each contributor)

Run `cf_team_join.rb` once to cache the shared private key locally and record who
you are on this machine:

```
<op-wrapper> read 'op://<shared-vault>/change-fabric team key: <team_id>/password' | \
  ruby scripts/cf_team_join.rb <team_id> <your-contributor-id> --stdin
```

Your `<your-contributor-id>` must match an `id` in the CHANGE.md
`contributors:` list. The script:

1. Reads the base64 private key from stdin (`--stdin`), or from the `CF_TEAM_KEY`
   env var, or, given neither, prints the `op read` hint above and exits.
2. Caches it in the macOS login Keychain under service `change-fabric-presence`,
   account `<team_id>` (with `-U`, so re-running updates rather than errors).
3. Writes your contributor id to `~/.claude/cf/teams/<team_id>/contributor_id`,
   the file the hooks read to resolve "which contributor am I".

## One time per team (optional): publishing findings artifacts

A completed `cf:change` sweep can publish its findings artifact to the hosted
artifacts service, which records the run and lists it on the team's findings
page in the platform web app. Skip this entirely if the team does not want
published artifacts; without a `contributors_team.platform:` block a sweep
behaves exactly as it always has.

There is no per-team provisioning script and no per-team AWS anything. The
service is one shared, Terraform-managed deployment (`platform/infra`), so
joining it is three steps in the web app and one on your machine:

1. **Create the organization and the team** in the platform web app, if they do
   not exist yet. Note both slugs.
2. **Mint a team API key** on the team's page. It is shown once. A key names a
   team and no person, which is what lets CI hold one.
3. **Add the block to `CHANGE.md`:**

   ```yaml
   contributors_team:
     team_id: my-team
     public_key_ed25519: <base64 verify-only key printed by cf_team_init.rb>
     contributors:
       - { id: pat, name: Pat Taylor }
     organization: my-org
     team: my-team
     platform:
       api_url: https://api.staging.changefabric.org
       api_key_env: CF_TEAM_API_KEY
   ```

   Nothing in that block is a credential. `api_key_env` names the environment
   variable the key arrives in, never the key.

4. **Store the key on your machine**, so it lives in neither the repo nor every
   shell's environment:

   ```
   <op-wrapper> read 'op://<shared-vault>/change-fabric platform key: my-org/my-team/credential' | \
     ruby scripts/cf_team_join.rb --platform my-org my-team --stdin
   ```

   It caches the key in the macOS login Keychain under service
   `change-fabric-platform`, account `<organization>/<team>` (with `-U`, so
   re-running rotates rather than errors). The publisher reads the named env var
   first and falls back to this entry, so CI supplies a key through the
   environment while a laptop needs none.

What a publish does: `POST /v1/artifacts` declares the run and every file in the
bundle and comes back with one presigned upload URL per file, the bytes go
straight to storage over those URLs, and `POST /v1/artifacts/:id/complete` says
it finished. The client needs only Ruby's standard library. It holds no AWS
credential, names no bucket, and invents no key prefix; the service assigns the
prefix, owns the index, and decides who may open a run (signed cookies for a
person's browser, presigned downloads for a machine).

Every step is best effort. A missing key, an unreachable API, or a failed upload
is a named warning on the run and never changes the sweep's pass/fail: the four
audit lanes are the release gate, and the artifact is the evidence attached to
it. The bundle is written to the Desktop either way.

If the deployment sits behind a coarse HTTP Basic Auth fence (staging does), add
`platform.basic_auth.username_env` and `platform.basic_auth.password_env` naming
the environment variables that hold it, and export them alongside the key.

### Migrating an already-registered team: `cf_team_migrate.rb`

The four steps above are the manual path, and they are fine for a team starting
from nothing. A team that already has a `cf_team_init.rb` registration (a
`team_id`, a public key, a roster) should use `cf_team_migrate.rb` instead: it
does the same thing in one run and, crucially, carries the OLD identity onto the
new team rather than creating an unrelated one.

```
CF_PLATFORM_PASSWORD='<your platform password>' \
CF_PLATFORM_BASIC_AUTH_USER=... CF_PLATFORM_BASIC_AUTH_PASSWORD=... \
  ruby scripts/cf_team_migrate.rb \
    --org <organization-slug> --team <team-slug> \
    --email <you@example.com> --dry-run
```

Run it with `--dry-run` first. It reports what it would create and writes
nothing at all, including not creating an account: if there is no platform
account for `--email` yet, it says so and stops rather than signing one up
behind a flag that promised not to write. Drop the flag to apply.

Pointed at a repo (the current directory unless `--repo` says otherwise), it
reads that repo's `contributors_team:` block and resolves or creates:

1. the **organization** named by `--org`,
2. a **team** (`--team`, default `core`) carrying the old `team_id` as its
   `legacyTeamId` and the old `public_key_ed25519` as its `publicKeyEd25519`,
3. **your own membership** of that team, which is what lets your browser open
   the artifacts it publishes,
4. one **contributor alias** per `contributors[]` entry, so a run attributed to
   `pat` still reads as `Pat Taylor` even though `pat` was never an account
   here. The alias links to a real account only when a **verified** address
   matches; otherwise it keeps the display name and links to nobody, which is
   the honest record for somebody who has not signed up,
5. a **repo link** for this repo's normalized `repo_id`, the same value
   `scripts/contributors_team.rb` computes,
6. a **team API key**.

It prints the replacement `contributors_team:` block and the `cf_team_join.rb
--platform` command for the key. It does not edit `CHANGE.md`; paste the block
in and commit it like any other change.

Re-running is safe. The organization, team, membership, aliases and repo link
are found and reused. A key is the one thing it cannot reuse, because a key is
shown once and is not recoverable even by the API, so every real run mints a
new one; revoke the ones you did not keep from the team's page in the web app.

**Nothing about the legacy fields changes.** `team_id`, `public_key_ed25519` and
`contributors` stay in `CHANGE.md`, stay valid, and stay the only thing presence
and secret-alerts read. The migration is additive: it adds `organization`,
`team` and `platform:` beside them. The two run in parallel permanently.

### Migrating from the 0.5.0 `artifacts:` block

The earlier design gave each team its own S3 bucket, CloudFront distribution,
Basic Auth credential, and DynamoDB manifest table, provisioned by a
`cf_artifacts_init.rb` script that no longer exists. The `artifacts:` fields
still parse at schema 0.6.0 and a repo carrying them still builds its bundle,
but the publisher no longer carries an AWS SDK, so nothing is uploaded and the
run says so. Replace the block with `organization`, `team`, and `platform:`
above. The legacy fields are removed at schema 0.7.0. This is the ONLY part of
`contributors_team` that is deprecated; the identity fields above are permanent.

## The capability env vars (all off by default)

Set the ones you want, per plan sections 9 and 10:

- `CF_TELEMETRY=1` enables the `SessionEnd` transcript upload (Capability A,
  `telemetry_emit.rb`).
- `CF_PRESENCE=1` enables the `PreToolUse` presence/collision probe on
  `Edit`/`Write`/`NotebookEdit` (Capability B, `presence_probe.rb`).
- `CF_SECRET_ALERTS=1` enables the `SessionStart` secret-alert poll and its
  `PostToolUse` acknowledgement (Capability C, `secret_alert_poll.rb` +
  `secret_ack.rb`).

## One time per machine (Capability A only): the API secret

`telemetry_emit.rb` authenticates the transcript upload with a shared secret sent
as `x-api-key`. Provision it once, out of band, into:

```
~/.claude/cf/telemetry/api-secret
```

a single-line file holding the secret value (the SSM `/cf-telemetry/api-secret`
value). If the file is absent, telemetry silently skips the upload. Capabilities
B and C do not use this file; they authenticate with the Keychain team key
provisioned by `cf_team_join.rb`.

## Notes

- The `ed25519` gem must be installed in the hook runtime for Capabilities B and
  C to sign. If it is missing the hooks fail open (presence never blocks an edit,
  the secret poll injects nothing). Capability A does not sign and does not need
  the gem.
- After changing any script here, re-run `install.rb` to sync the live install
  (`~/.claude/cf/bin/` and `~/.claude/settings.json`). `cf_team_init.rb`,
  `cf_team_join.rb` and `cf_team_migrate.rb` are human-run tools, not hooks, so
  they are intentionally not wired into `settings.json`.
- Those three are also the only scripts here that are NOT fail-soft. Every hook
  fails open so it can never crash a session; these are one-time provisioning
  tools, so a missing credential or a refused API call raises and exits nonzero
  rather than half-finishing quietly.
