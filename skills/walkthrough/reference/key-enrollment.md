# Key enrollment

Shared protocol for every paid cf script (cf:image, cf:roast, cf:narrate, cf:music, cf:b-roll, cf:prototype imagegen, and the cf:walkthrough render). It lives beside cf:walkthrough so it installs with the toolkit; every paid skill points here.

## Where keys come from

A key is resolved in this order, and the first hit wins:

1. The process environment (`OPENAI_API_KEY`, `ELEVEN_LABS_API_KEY` or `ELEVENLABS_API_KEY`, `GEMINI_API_KEY`).
2. The env file named by `CF_SECRETS_ENV`.
3. This project's entry in `~/.claude/cf/secrets.yml`: a per-provider override, then its `env_file`.
4. Nothing else. The global default is offered as the first choice when a project is enrolled, never used silently.

`secrets.yml` stores only pointers (an env file path, or the literal `env` for "process env only"), never a key value. A project is keyed by its git remote (host/path), or by its working directory when it has no remote. `install.rb` never creates or overwrites it.

## Exit 4 means enroll

When a paid call is actually needed and the project has no recorded choice, the script makes no call, prints exactly one stdout line, and exits 4:

```json
{"cf_enroll":{"provider":"openai","env_var":"OPENAI_API_KEY","project_key":"github.com/example/app","candidates":["~/secrets/example.env","env"]}}
```

A fully cached run never exits 4. On exit 4:

1. Parse the `cf_enroll` line. It never carries a value.
2. Ask one AskUserQuestion with header `Key source` (it fires even in away mode). Build the options from `candidates` in order: the first is the global default when one is set, labeled "global default"; then the other recorded env files; then `env`, labeled "process env only".
3. Record the answer:
   `ruby ~/.claude/cf/bin/cf_secrets_enroll.rb set --project-key <project_key> --source <choice> --env-var <env_var>`
4. On exit 2, show the stderr reason (missing file, variable name not in the file) and ask again. A stderr warning that the file sits in a git work tree and is not ignored is advice: pass it on.
5. Re-run the original command unchanged.

Ask once per project. A recorded choice whose file or variable later goes missing is a named error, not a new prompt; run `set` again to change it.

## Other commands

- `ruby ~/.claude/cf/bin/cf_secrets_enroll.rb default --source ~/secrets/example.env` sets the global default offered first.
- `ruby ~/.claude/cf/bin/cf_secrets_enroll.rb status` lists project keys, providers, and source paths, never values.
- `set ... --provider gemini --source ~/secrets/other.env` adds a per-provider override by hand; the agent never asks per provider.

## Never

Never read, cat, grep, or echo an env file, and never print or write a key, in output, logs, errors, or commits. Use placeholder paths like the ones above in any example.
