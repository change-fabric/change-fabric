# CF Enroll in Codex and other hosts without AskUserQuestion

When invoked as `$cf-enroll` (or loaded by a paid skill with its `cf_enroll`
line), run the same flow as SKILL.md, asking in plain conversation. For each
provider, ask one numbered question and wait for the answer before the next:

```
openai has no usable key for /path/to/app. Pick one:
1. Enroll now (recommended): run this in your own terminal:
   ruby ~/.claude/cf/bin/cf_keys.rb enroll openai --dir /path/to/app
   (add --scope tree to share it with projects below this folder)
2. Use the key enrolled at /path/to (only when one exists)
3. Use the upload page (cf-secret-intake), for when no terminal is at hand
4. Defer for 7 days (or say 1 day); paid steps skip until it lapses
```

Never ask the user to paste a key into the conversation. Run option 2 or 4
yourself (`cf_keys.rb confirm-inherit` or `cf_keys.rb defer --days N`); they
need no secret. For 1 or 3, wait for the user to say done, then run
`cf_keys.rb status --dir <root>` and confirm the provider reads `enrolled`
before handing back. The caller re-runs its paid step once; a second exit 4
stops with the status line.
