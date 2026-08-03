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

## One time per team (optional): the findings-artifact area

`cf_artifacts_init.rb` provisions the shared S3 + CloudFront area cf:change
publishes its findings artifacts to. Skip it entirely if the team does not want
published artifacts; without the `artifacts:` block a sweep behaves exactly as
it always has.

```
ruby scripts/cf_artifacts_init.rb <team_id> [--region us-east-1] [--bucket NAME]
```

Run it twice, by design. The first run finds no credential in SSM, generates a
high-entropy one, prints the `aws ssm put-parameter` and `op item create`
commands for you to review and run yourself, and provisions nothing. The second
run reads the credential back from SSM and creates:

1. a private S3 bucket (public access blocked, ACLs disabled, SSE-S3 on),
2. a CloudFront distribution reaching it through an Origin Access Control, with
   a bucket policy allowing only that distribution,
3. a CloudFront viewer-request function enforcing HTTP Basic Auth, carrying the
   SHA-256 digest of the credential (never the credential: a CloudFront function
   has no network access and cannot fetch a secret at request time), and
4. the `cf-change-artifacts` DynamoDB table the team index page is built from.

It then prints the `artifacts:` block to paste under `contributors_team:` in the
repo's `CHANGE.md`. Nothing in that block is a secret.

Rotating the viewer credential: write the new `username:password` to the same
SSM parameter, then run `ruby scripts/cf_artifacts_init.rb <team_id> --rotate`,
which republishes the function with the new digest and touches nothing else.

Publishing needs `aws-sdk-s3`, `aws-sdk-dynamodb`, and `aws-sdk-cloudfront`
installed for the runtime that runs `change_run.rb`; a missing gem is a named
warning on the run, never a failure. Provisioning also needs `aws-sdk-ssm`.

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
  `cf_artifacts_init.rb`, and
  `cf_team_join.rb` are human-run tools, not hooks, so they are intentionally not
  wired into `settings.json`.
