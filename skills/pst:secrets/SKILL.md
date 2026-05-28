---
name: pst:secrets
description: Personal credential drawer - 1Password by default (config-driven), AWS KMS+SSM as a flag-selectable backend; no plaintext on disk except an opt-in, auto-shredded session cache
argument-hint: '[set "<desc>" | get <NAME> [--fresh] | export <NAME...> [--fresh] | list | rm <NAME> | session start [<NAME...>|--all] [--ttl 12h] | session status | session end | config [--refresh|doctor|--project]] [--aws | --profile <p> | --account <a> --vault <v> | --semantic "<text>"]'
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
/pst:secrets get LINEAR_API_KEY --fresh   # bypass any live session cache, read the backend
/pst:secrets export OPENAI_API_KEY ...    # eval-able `export` lines
/pst:secrets list                         # names + pointers grouped by drawer (no values, no unlock)
/pst:secrets rm OLD_KEY                   # delete (backend item + local pointer)
/pst:secrets session start LINEAR_API_KEY OPENAI_API_KEY   # materialize for 12h (ONE unlock) → autonomous reads
/pst:secrets session start --all --ttl 4h # materialize every registered secret, 4h lifetime
/pst:secrets session status               # show the live session (expiry + names, no values)
/pst:secrets session end                  # shred the session cache now
/pst:secrets session install-hook         # register the SessionEnd shred hook (one time)
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
`"$SCRIPTS/secret_config.py"`, `"$SCRIPTS/session_cache.py"`, or
`"$SCRIPTS/provision_account.py"`.

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

**If a session cache is live** (see `session` below), `get`/`export` read from
it first - no backend unlock - and warm any backend miss back into it. Pass
`--fresh` (alias `--no-session`) to force a backend read.

### `session start|status|end|install-hook` - autonomous session cache

A deliberate, time-boxed convenience layer for when you'll be **away from the
machine** (can't do TouchID) or want to give the agent **more autonomy for a
single session**. `session start` resolves the named (or `--all`) secrets,
fetches each value **once** (a single unlock / MFA prompt), and materializes
them into a private, ephemeral cache under `$TMPDIR`. For the rest of the
session, `get`/`export` serve from that cache without re-prompting; you can also
`source "$(… session path)"` to load every value as env vars at once.

```bash
python3 "$SCRIPTS/session_cache.py" start LINEAR_API_KEY OPENAI_API_KEY --ttl 12h
python3 "$SCRIPTS/session_cache.py" status        # expiry + names (never values)
python3 "$SCRIPTS/session_cache.py" end           # shred now
python3 "$SCRIPTS/session_cache.py" install-hook  # one-time: SessionEnd shred hook
```

This **trades the "no plaintext on disk" guarantee** for the lifetime of the
session. It is defended by _short lifetime_, not by encryption:

- **TTL** (default **12h**, mirroring the `/aws-mfa` window; `--ttl 4h`, `45m`,
  `1h30m`, or a bare integer = minutes). Any access past the deadline purges.
- A **detached watchdog** shreds the cache at the deadline even if the session
  goes idle (the stepped-away case).
- A **Claude Code SessionEnd hook** (`install-hook`, idempotently added to
  `~/.claude/settings.json`) shreds when the session ends.
- The cache dir is `0700`, its files `0600`, under `$TMPDIR` (per-user,
  ephemeral, not synced/backed-up, OS-cleaned). "Shred" is best-effort
  overwrite-then-unlink - on SSD/APFS physical erasure is not guaranteed, so the
  real guarantee is the short lifetime + private location.

Treat session mode as "lower the gate for a while," never as "as safe as the
backend." For anything needing the hard MFA-deny gate, prefer `--aws` and skip
session mode.

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

**Session mode is the one exception** to "plaintext never on disk": it
materializes resolved values to a `0600` cache for a bounded window so the agent
can run unattended (see `session` above). It weakens both backends to "whoever
can read your `$TMPDIR` within the TTL," so don't use it for `--aws` secrets you
chose specifically for the MFA-deny gate.

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
- `scripts/secret_fetch.py` - `get` / `export` / `list` / `rm` (cache-first reads).
- `scripts/secret_config.py` - catalog & overlay management CLI.
- `scripts/session_cache.py` - opt-in session cache: materialize, lazy expiry,
  detached TTL watchdog, SessionEnd hook install, shred.
- `scripts/session_end_hook.sh` - Claude Code SessionEnd hook that shreds a live
  session cache on exit.
- `scripts/provision_account.py` - AWS KMS + key-policy setup (idempotent).
- `tests/` - pytest suite (registry migration, op/aws backends with mocked
  subprocesses, resolution/overlay/semantics, confirm-on-write, argv secrecy,
  session cache materialize/expiry/shred + cache-first reads).
  Run: `pytest skills/pst:secrets/tests -q`.

## Requirements

- **1Password:** `op` CLI 2.x **and** desktop app integration enabled
  (1Password → Settings → Developer → "Integrate with 1Password CLI"). Without
  it, `op account list` returns `[]` and `config --refresh` will tell you to
  enable it.
- **AWS (optional):** `aws` CLI + an MFA-authenticatable profile.
- `python3` (stdlib only - shells out to `op` / `aws`, no SDKs).
