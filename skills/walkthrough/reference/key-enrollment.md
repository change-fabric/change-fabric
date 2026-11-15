# Key enrollment

Shared protocol for every paid cf script (cf:image, cf:roast, cf:narrate, cf:music, cf:b-roll, cf:prototype imagegen, and the cf:walkthrough render). It lives beside cf:walkthrough so it installs with the toolkit; every paid skill points here.

## Where keys come from

Keys are per project. A project is its repository root (a worktree maps to its repo); a directory outside any repo is its own project. A key is resolved in this order:

1. This project's own enrolled key.
2. The nearest enrolled ancestor level (an org folder, a home dir), deepest first, and only when this project has a recorded confirmation for that exact ancestor.
3. Nothing else.

Keys live as hidden 0600 files under `~/.claude/cf/secrets/<slug>/`, beside a value-free `meta.json`. Process env vars (`OPENAI_API_KEY`, `ELEVEN_LABS_API_KEY`, `ELEVENLABS_API_KEY`, `GEMINI_API_KEY`, `CF_SECRETS_ENV`) and the old `~/.claude/cf/secrets.yml` are never key sources: a set variable earns one stderr warning naming it, never its value. There is no global fallback.

## Exit 4 means enroll

When a paid call is actually needed and the project has no usable key, the script makes no call, prints one `cf_enroll` JSON line plus a plain instruction, and exits 4:

```json
{"cf_enroll":{"provider":"openai","project_root":"/path/to/app","project_id":"github.com/example/app","snippet":"ruby ~/.claude/cf/bin/cf_keys.rb enroll openai --dir /path/to/app","inheritable_from":"/path/to"}}
```

A fully cached run never exits 4. On exit 4:

1. Parse the `cf_enroll` line. It never carries a value.
2. When `inheritable_from` is present, ask one AskUserQuestion: use the key enrolled at that ancestor for this project, or enroll a project key. On yes, run `ruby ~/.claude/cf/bin/cf_keys.rb confirm-inherit <provider> --dir <project_root>`. It records the confirmation and needs no secret.
3. Otherwise paste the `snippet` in chat for the user to run in their own terminal. It reads the key with echo off, validates it against the provider's free endpoint, and stores it. Never run it for the user and never ask for the key in chat.
4. Re-run the original command unchanged.

## Other commands

- `ruby ~/.claude/cf/bin/cf_keys.rb status [--dir PATH]` lists each provider as enrolled, inherited, inheritable, deferred, or missing, never a value.
- `ruby ~/.claude/cf/bin/cf_keys.rb defer <provider> [--dir PATH]` records a per-project deferral after an AskUserQuestion defer.
- `ruby ~/.claude/cf/bin/cf_keys.rb enroll <provider> --dir ~/org` enrolls an ancestor level that descendant projects may inherit from after confirmation.

## Never

Never read, cat, grep, or echo a key file or an env file, and never print or write a key, in output, logs, errors, argv, or commits. Use placeholder paths like the ones above in any example.
