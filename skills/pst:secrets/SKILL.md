---
name: pst:secrets
description: Personal credential drawer - 1Password by default (config-driven), AWS KMS+SSM as a flag-selectable backend; no plaintext on disk
argument-hint: '[set "<desc>" | get <NAME> | export <NAME...> | list | rm <NAME> | config [--refresh|doctor|--project]] [--aws | --profile <p> | --account <a> --vault <v> | --semantic "<text>"]'
allowed-tools: Bash, Read
---

# Secret drawer (1Password default · AWS KMS+SSM optional)

A place to stuff API keys and tokens **instead of plaintext on the filesystem**.
By default secrets land in **1Password** (via the `op` CLI); the AWS **KMS+SSM
SecureString** backend remains available behind `--aws` or a config profile.
Only a local _pointer registry_ (names + where the value lives, never values) is
kept on disk, so `list` needs no unlock.

Which backend a `set` uses is **config-driven**: a global catalog of your
1Password accounts/vaults plus per-project overlays produce a _suggested_
destination, and **every write confirms that destination before the value is
captured.**

> **Scope:** a _personal_ credential drawer, not a home for production /
> service-principal secrets. 1Password access is gated by the desktop app /
> CLI unlock state - it does **not** reproduce the AWS KMS server-side
> "deny decrypt without MFA" guarantee. If the app is already unlocked, a local
> process running as you can `op read` without a fresh prompt. Use `--aws` for
> anything that needs the harder MFA gate.

---

## Quick reference

```bash
/pst:secrets                              # status: doctor + list pointers
/pst:secrets set "my Linear API key"      # resolve → CONFIRM destination → browser capture (WRITE)
/pst:secrets set "..." --semantic "family shared vault"   # natural-language destination
/pst:secrets set "..." --account family --vault shared    # explicit op destination
/pst:secrets set "..." --profile aws      # or --aws : AWS KMS+SSM backend
/pst:secrets get LINEAR_API_KEY           # one value to stdout (capture in a var; never echo)
/pst:secrets export OPENAI_API_KEY ...    # eval-able `export` lines
/pst:secrets list                         # names + pointers grouped by drawer (no values, no unlock)
/pst:secrets rm OLD_KEY                   # delete (backend item + local pointer)
/pst:secrets config                       # first-run guided setup
/pst:secrets config --refresh             # rediscover op accounts/vaults
/pst:secrets config doctor                # validate CLI, auth, catalog, overlays, registry
/pst:secrets config --project             # write a per-project default overlay
```

## Resolve the bundled scripts (run once, harness-neutral)

```bash
SKILL_LINK="$HOME/.claude/commands/pst:secrets.md"
if [ -L "$SKILL_LINK" ]; then
  SCRIPTS="$(dirname "$(readlink -f "$SKILL_LINK")")/scripts"
elif [ -n "$CODEX_HOME" ] && [ -d "$CODEX_HOME/skills/pst:secrets/scripts" ]; then
  SCRIPTS="$CODEX_HOME/skills/pst:secrets/scripts"
else
  SCRIPTS="$(dirname "${BASH_SOURCE[0]:-$0}")/scripts"
fi
```

Then invoke `python3 "$SCRIPTS/secret_capture.py"`, `"$SCRIPTS/secret_fetch.py"`,
`"$SCRIPTS/secret_config.py"`, or `"$SCRIPTS/provision_account.py"`.

---

## Modes

### `set "<description>"` - capture (WRITE)

The single most important UX rule: **confirm the destination on every write.**
Because this skill runs inside an agent harness (the capture script's stdin is
not a TTY), confirmation is a **two-step handshake the agent drives** - the
script will _refuse_ to write non-interactively unless the confirmed drawer id
is passed back. Steps:

1. **Derive the field(s).** Infer an `ENV` name (`LINEAR_API_KEY`), a short
   `Label`, and a `hint` for each secret in the description.
2. **Resolve the destination (no write):**
   ```bash
   python3 "$SCRIPTS/secret_capture.py" --field LINEAR_API_KEY:"API Key" --resolve-only
   # → {"backend":"op","drawer_id":"op:acct:…:vault:…","describe":"op / family / Shared …","source":"…"}
   ```
   Pass through any `--profile/--account/--vault/--semantic/--aws` the user
   implied. The `describe`/`source` tell you (and them) _where_ it would land and
   _why_ (default profile, project overlay, flag, semantic match).
3. **Confirm with the user.** Show the resolved destination; let them accept or
   redirect (a different `--account/--vault`, `--semantic "the family shared
vault"`, or `--aws`). Re-run `--resolve-only` if they redirect.
4. **Capture, pinning the confirmed destination:**
   ```bash
   python3 "$SCRIPTS/secret_capture.py" \
     --field LINEAR_API_KEY:"API Key":"Settings → Security → API" \
     --confirm-destination "op:acct:…:vault:…"
   ```
   The script verifies `--confirm-destination` matches its own re-resolution,
   ensures the session/unlock, then opens a localhost-only masked form. On Save
   the value posts to `127.0.0.1`, is written to the backend, the pointer
   registry updates, and the server self-shuts.
5. **Refuse inappropriate material** (third-party PII with no service behind it);
   point the user at the right instrument. Harmless non-credentials are fine.
6. **Verify by name + presence only** - never print a value: `secret_fetch.py list`.

The value never touches stdout, the transcript, argv, shell history, temp files,
or plaintext disk. (A legacy `--backend file --out <path>` plaintext mode exists
for non-sensitive offline use; it is **not** the default and bypasses
resolution.)

### `get <NAME>` / `export <NAME...>` - consume (READ)

```bash
KEY=$(python3 "$SCRIPTS/secret_fetch.py" get LINEAR_API_KEY)
eval "$(python3 "$SCRIPTS/secret_fetch.py" export OPENAI_API_KEY ANTHROPIC_API_KEY)"
```

Reads resolve the secret's recorded drawer from the pointer registry - **no
destination prompt.** If the same `NAME` lives in more than one drawer, scope
with `--account/--vault/--aws`. `get` prints the raw value by design - only ever
capture it into a variable. A locked app / expired session ⇒ non-zero exit with
an actionable re-auth message.

### `list` / `rm <NAME>`

`list` groups pointers by drawer (no unlock, no values). `rm` deletes the
backend item (1Password items are **archived**, not hard-deleted) and the local
pointer.

### `config` - catalog, overlays, diagnostics

- **First run / `config`:** if there is no catalog, run guided setup - discover
  accounts/vaults (`config --refresh`), help the user alias them and pick a
  default profile. Never fall back silently.
- **`config --refresh`:** re-enumerate 1Password accounts/vaults via `op` and
  merge into the catalog (new vaults added; absent ones marked `missing_since`,
  never deleted; human aliases/labels preserved).
- **`config doctor`:** validate `op` availability, per-account unlock state,
  unique aliases, overlay trust, and registry/catalog consistency.
- **`config --project [--profile P | --account A --vault V]`:** write a
  `.pst-secrets.json` overlay setting this area's default destination. Refused
  unless the directory is under a `trusted_overlay_roots` entry.

### `provision` - AWS only, one-time per account (idempotent)

```bash
PST_SECRETS_PROFILE=<profile> python3 "$SCRIPTS/provision_account.py" --region <region>
```

Stands up the KMS key + `DenyDecryptWithoutMFA` key policy for an AWS account.
1Password vaults are **not** provisioned here - use `config --refresh`.

---

## Config model (two layers)

- **Global catalog** `~/.config/pst-secrets/config.json` (0600): discovered
  1Password accounts + vaults (stable IDs + human aliases + `semantic_labels`),
  AWS accounts, named drawer `profiles`, a `default_profile`, and
  `trusted_overlay_roots`.
- **Project overlays** `.pst-secrets.json` (walked up from cwd, **honoured only
  under a trusted root**): set a preferred default destination for a workspace
  area. Carry routing preferences only - never secrets. Keep gitignored unless
  you intend to share routing metadata.

**Resolution precedence (writes):** explicit flag / `--semantic` →
trusted project overlay → global `default_profile` → guided choice. The result
is always _confirmed_ before capture.

`--profile` is the **drawer profile** (a catalog entry). The AWS CLI profile is
configured per AWS account in the catalog (or via `PST_SECRETS_PROFILE`), so the
two never collide.

## Backends & security tradeoff

|                       | 1Password (default)                                | AWS SSM (`--aws`)                                                |
| --------------------- | -------------------------------------------------- | ---------------------------------------------------------------- |
| Gate                  | desktop app / CLI unlock (biometric)               | live MFA session **+** KMS key policy denies decrypt without MFA |
| Already-unlocked risk | a local process can `op read` with no fresh prompt | even leaked long-lived creds can't decrypt                       |
| Best for              | day-to-day personal keys                           | secrets needing the harder MFA gate                              |

Both: plaintext never on disk; values reach the backend only via stdin
(1Password JSON template / AWS `--cli-input-json`), never on argv.

## Multiple accounts & vaults

The catalog spans every account you can reach (e.g. REDACTED employee + shared +
project vaults; personal private; Taylor family shared). The registry namespaces
pointers by **stable drawer id** (`op:acct:<id>:vault:<id>` /
`aws:account:<id>:region:<r>:prefix:<p>`), so identical names never collide and
vault/account renames don't corrupt pointers.

## Files

- `scripts/config.py` - catalog, `op` discovery, trusted overlays, resolution, semantics.
- `scripts/registry.py` - shared v2 pointer registry + v0/v1 migration.
- `scripts/backend.py` - `SecretBackend` Protocol + factory.
- `scripts/op_secrets.py` - 1Password backend (`OnePasswordBackend`).
- `scripts/aws_secrets.py` - AWS SSM backend (`AwsSsmBackend`) + env-driven core.
- `scripts/secret_capture.py` - browser capture (WRITE) + confirm-on-write.
- `scripts/secret_fetch.py` - `get` / `export` / `list` / `rm`.
- `scripts/secret_config.py` - catalog & overlay management CLI.
- `scripts/provision_account.py` - AWS KMS + key-policy setup (idempotent).
- `tests/` - pytest suite (registry migration, op/aws backends with mocked
  subprocesses, resolution/overlay/semantics, confirm-on-write, argv secrecy).
  Run: `pytest skills/pst:secrets/tests -q`.

## Requirements

- **1Password:** `op` CLI 2.x **and** desktop app integration enabled
  (1Password → Settings → Developer → "Integrate with 1Password CLI"). Without
  it, `op account list` returns `[]` and `config --refresh` will tell you to
  enable it.
- **AWS (optional):** `aws` CLI + an MFA-authenticatable profile.
- `python3` (stdlib only - shells out to `op` / `aws`, no SDKs).
