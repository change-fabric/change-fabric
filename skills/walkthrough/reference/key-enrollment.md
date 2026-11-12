# Key enrollment

Shared protocol for every paid cf script (cf:image, cf:roast, cf:narrate, cf:music, cf:b-roll, cf:prototype imagegen, and the cf:walkthrough render). It lives beside cf:walkthrough so it installs with the toolkit; every paid skill points here.

## Keys are per project

Each paid provider key (OpenAI, ElevenLabs, Gemini) belongs to exactly one project. A project is a repository (a worktree maps to its repo); a directory outside any repo is its own project. Keys are stored as hidden 0600 files under `~/.claude/cf/secrets/<project>/`, beside a `meta.json` that holds no key material.

A key is resolved in this order, and nothing else is consulted:

1. This project's own enrolled key.
2. The nearest enrolled ancestor level (an org folder or a home directory, deepest first), only after this project confirmed it may use that key.

Environment variables (`OPENAI_API_KEY`, `ELEVENLABS_API_KEY`, `ELEVEN_LABS_API_KEY`, `XI_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `CF_SECRETS_ENV`) and the old `~/.claude/cf/secrets.yml` pointers are ignored. A set variable earns one stderr warning naming it, never its value. Every project enrolls through the CLI below.

## Enrolling

Only the user types a key, and only into `cf_keys.rb` at their own terminal. Paste them the snippet; never ask for the key in chat:

```
ruby ~/.claude/cf/bin/cf_keys.rb enroll openai --dir '/path/to/project'
```

`enroll` refuses piped input (exit 2), reads the key with echo off, and always makes the provider's free validation call before storing anything: a rejected key or no network exits 3 and stores nothing. `--dir` names the level: a repo root is that repo; any other directory (an org folder, `~`) is a level that descendant projects may inherit from after confirmation.

## Exit 4 means enroll

When a paid call is actually needed and this project has no usable key, the script makes no call, prints one `cf_enroll` JSON line plus the snippet, and exits 4:

```json
{"cf_enroll":{"provider":"openai","project_root":"/path/to/project","project_id":"repo:github.com/example/app","snippet":"ruby ~/.claude/cf/bin/cf_keys.rb enroll openai --dir /path/to/project"}}
```

A fully cached run never exits 4. A deferred provider still exits 4. On exit 4:

1. If the line carries `inheritable_from`, ask one AskUserQuestion: may this project use the key enrolled at that directory? On yes run `ruby ~/.claude/cf/bin/cf_keys.rb confirm-inherit <provider> --dir '<project_root>'` and re-run. Never inherit without asking.
2. Otherwise paste the `snippet` for the user to run, wait until they say it succeeded, and re-run the original command unchanged.

## SessionStart prompt

Skills declare their paid providers in SKILL.md frontmatter (`providers: [openai]`), and install records them. At SessionStart, each project is checked for every required provider it has not enrolled, confirmed inheriting, or deferred, and the agent asks with AskUserQuestion: enroll now (paste the snippet), use the ancestor key (only when one exists; run `confirm-inherit`), or defer for this project (run `ruby ~/.claude/cf/bin/cf_keys.rb defer <provider> --dir '<project_root>'`). Deferral is per provider and per project, and only silences that prompt.

## Other commands

- `ruby ~/.claude/cf/bin/cf_keys.rb status [--dir PATH]` lists each provider as enrolled, inherited, inheritable, deferred, or missing, never a value.
- `ruby ~/.claude/cf/bin/cf_keys.rb remove <provider> [--dir PATH]` deletes a key; it needs a real terminal too.

## Never

Never read, cat, grep, or echo anything under `~/.claude/cf/secrets` (a PreToolUse guard denies it), never ask for or accept a key in chat (a UserPromptSubmit guard blocks a prompt that looks like one), and never print or write a key in output, logs, errors, or commits. Use placeholder paths like the ones above in any example.
