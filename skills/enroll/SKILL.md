---
name: cf:enroll
group: workflow
description: Enrolls the paid API keys (OpenAI, ElevenLabs, Gemini) that installed cf skills need, one question per provider. Run directly it covers every installed provider (or the ones named); a paid skill that exits 4 loads it with its cf_enroll line. Offers the cf_keys.rb snippet for the user's own terminal (project scope by default, tree scope on request), confirm-inherit of an ancestor key, the cf:secret-intake upload page as a fallback, or a deferral of 1 or 7 days. Never asks for a key in chat.
---

# CF enroll

Trigger: `/cf:enroll [provider...]`, or loaded by name by a paid skill with
its `cf_enroll` line. The full key protocol (resolution order, expiry, exit
codes) is `reference/key-enrollment.md` once it moves here; until then it is
the cf:walkthrough copy.

## Input

One of three:

- Nothing (a direct run): every provider in `required_providers` of
  `~/.local/share/change-fabric/installation.json`, the paid providers the
  installed skills declare.
- Provider names (`openai`, `elevenlabs`, `gemini`): only those.
- One `{"cf_enroll":{...}}` JSON line (an implicit run): only its `provider`,
  for its `project_root`. Take the line exactly as the paid skill passed it.
  Its `reason` (`missing`, `expired`, `revoked`) shapes the question;
  `inheritable_from` adds the inherit option; `snippet` and `correct` are the
  commands to offer.

The project is `project_root` from the line, else the current directory's
project. Start with `ruby ~/.claude/cf/bin/cf_keys.rb status --dir <root>`; it
never prints a value. Skip a provider that already reads `enrolled`,
`inherited from`, or `deferred until` (unless the line itself named it),
but never one whose entry says `(expired)`: treat that as `reason` `expired`
and ask the renewal question for its owning level.

## One question per provider

Ask with AskUserQuestion where the host has it, one question per provider;
on a host without it, ask the same options as a plain numbered question and
wait for the answer (`reference/codex.md`). Options:

1. Enroll now (recommended). Paste the snippet for the user to run in their
   own terminal: `ruby ~/.claude/cf/bin/cf_keys.rb enroll <provider> --dir <root>`.
   Project scope is the default; offer `--scope tree` when the root is an org
   or home folder whose descendant projects should share the key. It reads the
   key with echo off and validates it. Never run it for the user.
2. Use the ancestor key (only when `inheritable_from` is set, or status says
   `inheritable from`): run `ruby ~/.claude/cf/bin/cf_keys.rb confirm-inherit <provider> --dir <root>`.
   It records a confirmation and needs no secret.
3. Use the upload page (fallback, for a user with no terminal at hand): use
   cf:secret-intake by name, `secret_intake.rb intake --name <ENV_NAME> --validate <provider>`,
   then `secret_intake.rb push <ENV_NAME> --to cf-key:<provider> --dir <root>`.
4. Defer: run `ruby ~/.claude/cf/bin/cf_keys.rb defer <provider> --dir <root> --days 7`
   (or `--days 1`; 7 is the default). Until it lapses, paid steps needing that
   provider here skip with one note and exit 5; the next paid run after it
   lapses asks again.

On `reason` `expired`, option 1 renews at `owner_root`; if the user says only
the recorded date is wrong, paste `correct` with their date instead. On
`revoked`, option 1 enrolls a new key at `owner_root`.

Never ask the user to paste a key into the chat, and never echo one. If a key
appears in chat anyway, do not repeat it; tell the user to revoke it.

Away mode: take Defer (7 days) as the safe default and report it.

## After the answer

For enroll or the upload page, wait for the user to say done, then run
`cf_keys.rb status --dir <root>` and confirm the provider reads `enrolled` or
`inherited from`. Then return: an implicit run hands back to the paid skill,
which re-runs its paid step once. If that re-run exits 4 again, stop and
report the status line; never loop. A deferral returns too, and the caller
continues without the paid output.

## Where callers find this skill

A paid skill loads the installed copy, never a repo path, and passes the
`cf_enroll` line verbatim:

| Host | Installed path |
| --- | --- |
| Claude Code | `~/.claude/skills/cf:enroll/SKILL.md` |
| Codex | `~/.agents/skills/cf-enroll/SKILL.md` (invoke as `$cf-enroll`) |
| Copilot | `~/.copilot/skills/cf-enroll/SKILL.md` |
| OpenCode | `$XDG_CONFIG_HOME/opencode/skills/cf-enroll/SKILL.md`, else `~/.config/opencode/skills/cf-enroll/SKILL.md` |
| Pi | `~/.pi/agent/skills/cf-enroll/SKILL.md` |
