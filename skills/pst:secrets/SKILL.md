---
name: pst:secrets
description: Encrypted AWS secret drawer - KMS+SSM SecureString, MFA-gated, multi-account; no plaintext on disk
argument-hint: '[set "<desc>" | get <NAME> | export <NAME...> | list | rm <NAME> | provision] [--profile <p>]'
allowed-tools: Bash, Read
---

# Secret drawer (AWS KMS + SSM)

A place to stuff API keys and tokens **instead of plaintext on the filesystem**.
Secrets are KMS-encrypted into AWS SSM Parameter Store **SecureString** values;
only a local _pointer registry_ (names/paths, never values) is kept on disk.
Reading requires a **live MFA'd AWS session** - enforced both by the tooling and
by the KMS key policy itself.

> **Scope:** this is a _personal credential drawer_, not a home for
> production / service-principal secrets. Those belong in their own systems with
> service-role access (even if in the same AWS account) - the all-principals
> MFA-deny key policy here deliberately makes this drawer unusable by unattended
> automation.

---

## Quick reference

```bash
/pst:secrets                          # status: session check + list pointers (grouped by account)
/pst:secrets set "my Linear API key"  # browser capture → KMS-encrypt → SSM (WRITE)
/pst:secrets get LINEAR_API_KEY       # decrypt one value to stdout (capture in a var; never echo)
/pst:secrets export OPENAI_API_KEY ANTHROPIC_API_KEY   # eval-able `export` lines
/pst:secrets list                     # known names + pointers, grouped by account (no values)
/pst:secrets rm OLD_KEY               # delete (SSM parameter + local pointer)
/pst:secrets provision                # idempotent: create KMS key + MFA-deny policy in an account
```

All operations need a live session (mint one with `/aws-mfa personal <otp>` or
the equivalent for another profile). `list` is the exception - it reads only the
local pointer registry and needs no session.

## Configuration (env-driven; nothing baked into the lib)

The scripts read these env vars; defaults shown are the maintainer's personal
account, override per-call for other accounts:

```
PST_SECRETS_PROFILE=pstaylor-mfa      # AWS CLI profile w/ a live MFA session
PST_SECRETS_REGION=us-east-1
PST_SECRETS_KMS_KEY=alias/pst-secrets # customer-managed CMK
PST_SECRETS_PREFIX=/pst-secrets       # SSM parameter name prefix
```

## Resolve the bundled scripts (run once, harness-neutral)

```bash
SKILL_LINK="$HOME/.claude/commands/pst:secrets.md"
if [ -L "$SKILL_LINK" ]; then                       # Claude Code: file symlink
  SCRIPTS="$(dirname "$(readlink -f "$SKILL_LINK")")/scripts"
elif [ -n "$CODEX_HOME" ] && [ -d "$CODEX_HOME/skills/pst:secrets/scripts" ]; then
  SCRIPTS="$CODEX_HOME/skills/pst:secrets/scripts"  # Codex: dir symlink
else
  SCRIPTS="$(dirname "${BASH_SOURCE[0]:-$0}")/scripts"  # run from repo / Pi wrapper
fi
```

Then invoke `python3 "$SCRIPTS/secret_capture.py"`, `"$SCRIPTS/secret_fetch.py"`,
or `"$SCRIPTS/provision_account.py"`. Pass config via the env vars above.

---

## Modes

### `set "<description>"` - capture (WRITE)

The user describes, in plain language, _what_ to capture. Translate that into a
`secret_capture.py --backend aws-ssm` invocation - no interview unless genuinely
ambiguous:

1. **Derive the field(s).** Infer for each secret an `ENV` name (SCREAMING_SNAKE -
   "Linear API key" → `LINEAR_API_KEY`), a short `Label`, and a `hint` (where to
   get it) when known. Multiple secrets in one description → multiple `--field`.
2. **Refuse inappropriate material.** This is for _credentials/tokens the user
   controls_. Decline sensitive third-party PII with no service behind it (e.g.
   someone else's SSN) - point them at the right instrument (a W-9, a CPA's
   secure intake). Harmless non-credentials (a recovery answer) are fine.
3. **Ensure the session first.** If no live MFA session for the target profile,
   tell the user to run `/aws-mfa <account> <otp>` - the capture script fails
   fast without one.
4. **Report the plan, then run it** (it opens a localhost-only masked form):
   ```bash
   PST_SECRETS_PROFILE=pstaylor-mfa PST_SECRETS_REGION=us-east-1 \
   PST_SECRETS_KMS_KEY=alias/pst-secrets PST_SECRETS_PREFIX=/pst-secrets \
   python3 "$SCRIPTS/secret_capture.py" --backend aws-ssm \
     --title "Linear credentials" \
     --field LINEAR_API_KEY:"API Key":"Settings → Security & access → API"
   ```
5. **Verify by name + presence only** - never print a value: `… secret_fetch.py list`.

On Save the value posts to `127.0.0.1`, gets KMS-encrypted into SSM, the local
pointer registry updates, and the server self-shuts. The value never touches
stdout, the transcript, or plaintext disk. (A legacy `--backend file` plaintext
mode exists for non-sensitive offline use; it is **not** the default.)

### `get <NAME>` / `export <NAME...>` - consume (READ)

```bash
KEY=$(PST_SECRETS_PROFILE=pstaylor-mfa python3 "$SCRIPTS/secret_fetch.py" get LINEAR_API_KEY)
eval "$(PST_SECRETS_PROFILE=pstaylor-mfa python3 "$SCRIPTS/secret_fetch.py" export OPENAI_API_KEY ANTHROPIC_API_KEY)"
```

`get` prints the raw value by design - only ever capture it into a variable; do
not let it reach the terminal/transcript. Expired session ⇒ non-zero exit with a
"re-auth" message.

### `list` / `rm <NAME>`

`list` groups pointers by account (no session, no values). `rm` deletes the SSM
parameter and the local pointer, scoped to the authenticated account.

### `provision` - one-time per account (idempotent)

Stand up the KMS key + MFA-deny policy for a new account (personal or client),
with a live session for that account's profile:

```bash
PST_SECRETS_PROFILE=<profile> python3 "$SCRIPTS/provision_account.py" --region <region>
```

Creates the CMK + `alias/pst-secrets` if absent (reuses if present) and
(re-)asserts the `DenyDecryptWithoutMFA` key policy, then prints the env block.
Safe to re-run.

---

## How the MFA gate works (two layers)

1. **Tooling preflight** - every read/write runs `sts get-caller-identity`
   first; a dead session fails with a "run `/aws-mfa`" message.
2. **KMS key policy** - the CMK denies `kms:Decrypt`/`kms:ReEncryptFrom` unless
   `aws:MultiFactorAuthPresent` is true (`BoolIfExists`, so absent ⇒ denied). So
   **even leaked long-lived/non-MFA credentials cannot decrypt.** Policy
   management is _not_ denied, so the account root can always revert it - no
   lockout risk.

## Multiple AWS accounts

Be authenticated to each profile simultaneously and point each call at the right
one via the env vars (e.g. `PST_SECRETS_PROFILE=cas360
PST_SECRETS_KMS_KEY=alias/<their-key>`). The local pointer registry
(`~/.config/pst-secrets/registry.json`, 0600) is **namespaced by AWS
account**, so identical names never collide; `get`/`put`/`rm` scope to the
authenticated account and `list` groups by account. Each new account needs
`provision` run once.

## Files

- `scripts/aws_secrets.py` - generic core lib (store/fetch/delete +
  account-namespaced registry + session preflight). **No account/region baked
  in** - env-driven. Keep it generic.
- `scripts/secret_capture.py` - browser capture (WRITE), `--backend aws-ssm`.
- `scripts/secret_fetch.py` - `get` / `export` / `list` / `rm`.
- `scripts/provision_account.py` - idempotent per-account KMS + key-policy setup.
- `tests/test_aws_secrets.py` - 22 unit tests (migration, namespacing, quoting,
  failures); AWS-mocked, fast. Run: `pytest skills/pst:secrets/tests -q`.

## Requirements

- `aws` CLI configured; a profile that can be MFA-authenticated.
- `python3` (stdlib only - shells out to `aws`, no boto3).
- An MFA session for the target account (e.g. via `/aws-mfa`).
