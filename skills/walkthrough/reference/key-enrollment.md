# Key enrollment

Shared protocol for every paid cf script (cf:image, cf:roast, cf:narrate, cf:music, cf:b-roll, cf:prototype imagegen, and the cf:walkthrough render). It lives beside cf:walkthrough so it installs with the toolkit; every paid skill points here.

## Where keys come from

Keys are per project. A project is its repository root (a worktree maps to its repo); a directory outside any repo is its own project. A key is resolved in this order:

1. This project's own enrolled key.
2. The nearest enrolled ancestor level (an org folder, a home dir), deepest first, and only when this project has a recorded confirmation for that exact ancestor, or that ancestor enrolled its key with `--scope tree`.
3. Nothing else.

The default scope is per project: a descendant needs its own confirm-inherit. `--scope tree` is opt-in per key and shows in `status`. A project's own key always wins, and a deeper project-scoped level still stands between a project and a tree-scoped one above it.

## Expiry

Providers do not report when a key expires, so the date is recorded: `enroll --expires DATE` or `cf_keys.rb expires <provider> DATE`. A bare date means 00:00 UTC; full ISO8601 is accepted. All comparisons are UTC. The level that owns the resolved key decides: an inherited key uses its ancestor's date.

- Within 24 hours of expiry, resolving the key prints one stderr warning naming the provider, label, owning level, and the renew command. The call still runs.
- Once the date has passed, the key is refused locally: no paid request is made and the script exits 4 with `"reason":"expired"`.
- At SessionStart, every project's meta.json in the secret store is scanned (never a key file), and any key already expired or expiring within 24 hours is named with its provider, label, project root, and renew command.

Keys live as hidden 0600 files under `~/.claude/cf/secrets/<slug>/`, beside a value-free `meta.json`. Process env vars (`OPENAI_API_KEY`, `ELEVEN_LABS_API_KEY`, `ELEVENLABS_API_KEY`, `GEMINI_API_KEY`, `CF_SECRETS_ENV`) and the old `~/.claude/cf/secrets.yml` are never key sources: a set variable earns one stderr warning naming it, never its value. There is no global fallback.

## Exit 4 means enroll

When a paid call is actually needed and the project has no usable key, the script makes no call, prints one `cf_enroll` JSON line plus a plain instruction, and exits 4. `reason` says why: `missing` or `expired`.

```json
{"cf_enroll":{"provider":"openai","project_root":"/path/to/app","project_id":"github.com/example/app","reason":"missing","snippet":"ruby ~/.claude/cf/bin/cf_keys.rb enroll openai --dir /path/to/app","inheritable_from":"/path/to"}}
```

An expired key adds the owning level, its label and date, and the command that corrects a wrong date:

```json
{"cf_enroll":{"provider":"openai","project_root":"/path/to/app","project_id":"github.com/example/app","reason":"expired","owner_root":"/path/to","label":"team billing","expires_at":"2026-01-01T00:00:00Z","snippet":"ruby ~/.claude/cf/bin/cf_keys.rb enroll openai --dir /path/to","correct":"ruby ~/.claude/cf/bin/cf_keys.rb expires openai YYYY-MM-DD --dir /path/to"}}
```

A fully cached run never exits 4. On exit 4:

1. Parse the `cf_enroll` line. It never carries a value.
2. When `inheritable_from` is present, ask one AskUserQuestion: use the key enrolled at that ancestor for this project, or enroll a project key. On yes, run `ruby ~/.claude/cf/bin/cf_keys.rb confirm-inherit <provider> --dir <project_root>`. It records the confirmation and needs no secret.
3. Otherwise paste the `snippet` in chat for the user to run in their own terminal. It reads the key with echo off, validates it against the provider's free endpoint, and stores it. Never run it for the user and never ask for the key in chat.
4. Re-run the original command unchanged.

On `"reason":"expired"`, paste the `snippet` to renew the key at `owner_root`. If the user says the key has not expired and only the date is wrong, paste `correct` with their date instead. Neither needs a confirm-inherit.

On `"reason":"revoked"`, the provider answered 401 or 403: the key at `owner_root` was revoked or is invalid. Paste the `snippet` so the user can enroll a new key, then re-run. It is never retried.

## Provider failures

Every paid client (roast, image, b-roll, narrate, music) names an HTTP failure from the provider with one shared class (`scripts/cf_provider_error.rb`). Each message is scrubbed of the key and of anything shaped like a provider key, and each class carries a next step.

| Class | When | Exit |
| --- | --- | --- |
| `auth_revoked` | 401 or 403 | 4, `cf_enroll` with `"reason":"revoked"` |
| `quota_exhausted` | OpenAI 429 `insufficient_quota`, ElevenLabs 402 (or its 401 `quota_exceeded`) | 1, never retried |
| `rate_limited` | any other 429, after 3 attempts honouring `retry-after` (capped at 60s) | 1 |
| `bad_request` | 400 and any other 4xx, with the provider's message | 1 |
| `server` | 5xx | 1 |

Exit 1 prints one JSON line with no value, then a plain message:

```json
{"cf_key_error":{"provider":"openai","class":"quota_exhausted","status":429,"next_step":"the OpenAI account is out of credit or over its usage limit; add credit or raise the limit in its billing settings, then rerun (not retried)"}}
```

Relay the `next_step` to the user. On the optional paths (b-roll's Ken Burns fallback, the walkthrough draft roast) an expired key, a revoked key, or an empty quota still stops the run, since the user must fix them. A rate limit after retries, a bad request, or a server fault still falls back or skips with a note.

## Other commands

- `ruby ~/.claude/cf/bin/cf_keys.rb status [--dir PATH]` lists each provider as enrolled, inherited, inheritable, deferred, or missing, with any label, tree scope, expiry date and days left, never a value.
- `ruby ~/.claude/cf/bin/cf_keys.rb expires <provider> DATE [--dir PATH]` records or corrects the expiry of the key enrolled at that level, without re-entering it. It exits 3 when that level has no key for the provider.
- `ruby ~/.claude/cf/bin/cf_keys.rb defer <provider> [--dir PATH]` records a per-project deferral after an AskUserQuestion defer.
- `ruby ~/.claude/cf/bin/cf_keys.rb enroll <provider> --dir ~/org` enrolls an ancestor level that descendant projects may inherit from after confirmation. Add `--scope tree` to let them inherit without one, `--expires DATE` to record when it stops, and `--label TEXT` to name it in status and warnings. Re-enrolling replaces all three.
- `ruby ~/.claude/cf/bin/cf_keys.rb remove <provider> [--dir PATH]` deletes this project's key for that provider. Like `enroll`, it refuses without a real terminal.

## Hooks

- At SessionStart, for each provider an installed skill needs that this project has not enrolled, confirmed, or deferred, the agent is told to ask with AskUserQuestion: enroll now, use the ancestor key (only offered when one exists), or defer. A defer silences that prompt for this project and provider only; a later paid call still exits 4 with the snippet.
- A UserPromptSubmit guard blocks any chat prompt shaped like a provider key before the model sees it and points the user at `cf_keys.rb enroll`.

## Never

Never read, cat, grep, or echo a key file or an env file, and never print or write a key, in output, logs, errors, argv, or commits. Use placeholder paths like the ones above in any example.
