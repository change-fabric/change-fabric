---
name: cf:inbox
description: Runs the role-keyed agent-handoff inbox for multi-session work -- a human-edited roster, per-role inbox directories, an append-only ledger, and a bind/append/pick/done lifecycle -- so sessions in different roles can hand off work with a paper trail instead of a live message. Invoked directly to init a project's inbox, bind a session to a role, or drive any verb; the UserPromptSubmit and SessionEnd hooks surface a bound role's pending items and commit the inbox tree without being asked.
---

# CF Inbox

A role-keyed handoff protocol for multi-session agent work: a roster of role
names, a directory per role holding pending items as small markdown files, one
append-only ledger of every state change, and a thin CLI (`scripts/inbox_store.rb`)
that every verb below drives. This is not a live chat: it is a store. Nothing in
it sends a message to anyone; it only ever writes a file.

Trigger: `ruby ~/.claude/cf/bin/inbox_store.rb <verb> [args]`, invoked directly
or via this skill whenever a project's work is being handed off between roles
or sessions.

## Setup

A project opts in with **either**:

- An `inbox_root:` key at the top level of `CHANGE.md` frontmatter (sibling to
  `change_config:`/`change_policy:`, read directly, never through
  `ChangeConfig`), pointing at a directory one or more repos share, e.g.
  `inbox_root: ~/notes/team-handoff`. This is how one team spans several repos
  with a single inbox.
- Nothing at all: the tool falls back to a zero-config default,
  `~/.claude/cf/inbox/<dashed-cwd>/`, keyed the same way `cf:ctx` keys its own
  store.

`INBOX_ROOT` in the environment overrides both, for tests and one-off use.
`inbox_store.rb root` prints `{"root":...,"source":"env|change_md|default"}`
so a confused operator can see which rule fired.

Either way, the root has **no roles** until `init` runs once:

```
inbox_store.rb init --roles PLAN,BUILD,QA
```

This writes `roster.json` (the sole source of truth for the role set -- hand-
editable afterward) and creates `inbox/<ROLE>/`, `done/`, `done/artifacts/`,
`status/`, `ledger/`, and an empty `LEDGER.md`. Every role-taking verb refuses
with `{"error":"no_roster",...}` until `init` has run, naming the actual init
command in its `hint`. `done/artifacts/` has no verb of its own; it is a plain
directory for files a `done` item's body points at.

## Verbs

| Verb | Purpose |
|---|---|
| `init --roles A,B,C` | One-time: write `roster.json` and the directory tree. Refuses if a roster already exists. |
| `bind <ROLE> [--session-name N]` | Bind this session to a role for the hooks below. Writes the session's role to its per-session store; `--session-name` also records this role's cross-session `SendMessage` name in the roster. |
| `append <ROLE> --from <ROLE> --subject S [--refs R] [--body-file F]` | File a new pending item in `<ROLE>`'s inbox and log one ledger line. Prints the doorbell (see below). |
| `announce --from <ROLE> --subject S [--body-file F]` | Broadcast a read-only FYI item into every role's inbox at once (`status: fyi`), one ledger line total. Never shows up in `pending`/`list`; exists so N roles never independently react to the same news and file duplicate work. |
| `list --role <ROLE>` | Show that role's pending (and blocked) items. |
| `pick <path>` | Claim an item: `pending` -> `in-progress`. Does not touch `blocked`. |
| `done <path> [--blocked] [--clause C]` | Move an item to `done/` (numbered suffix on a same-stamp collision, never overwritten), or flip it to `blocked` with `--blocked`. Logs a ledger clause. |
| `unblock <path>` | Return a `blocked` item to `pending`, logged like any other transition. Refuses on an item that is not blocked. |
| `status [--role <ROLE>]` | Print each role's (or one role's) `status/<ROLE>.md` body verbatim. |
| `stamp <ROLE>` | Rewrite `status/<ROLE>.md`'s `Updated` line to now, preserving its freeform Notes. |
| `ledger <FROM> <TO> <STATUS> <SLUG> <clause...>` | Append one ledger line built from those fields; no-argument tail printing is not implemented. |
| `commit` | Commit the inbox root if it is a git repo and dirty; silent no-op otherwise. |
| `root` | Print the resolved root and which resolution rule fired. |

Every verb prints one JSON line and exits non-zero whenever that line carries
an `"error"` key -- scriptable and honest, never a silent no-op dressed as
success.

## The handoff ritual

1. **Bind once per session:** `bind BUILD` (or with `--session-name` the first
   time, so the roster can name this session in a doorbell for humans).
2. **Read your pending list:** `list --role BUILD`, or just start the session
   and let the UserPromptSubmit hook show it.
3. **Pick** an item before working it, so a second session in the same role
   does not duplicate the effort: `pick inbox/BUILD/2026...-slug.md`.
4. **Do the work.**
5. **Close it out:** `done <path>` on success, `done <path> --blocked` when it
   cannot proceed (then someone runs `unblock` later, never `pick`).
6. **Hand off:** `append <NEXT_ROLE> --from BUILD --subject "..."` for the next
   step in the chain, with a body that stands alone -- the reader has no other
   context.
7. **Ring the doorbell yourself.** See below: filing the item is not enough.

## The doorbell: writing is not sending

`append` and `announce` print a ready-to-send one-line message naming the
exact next step, e.g. `notify QA: 1 new item in inbox/QA`. That is the tool's
entire contribution to delivery. **The tool never sends anything** -- it has
no channel, no `SendMessage` call, no notification. Writing the item and
delivering word of it are two separate actions on purpose: a broadcast landing
silently in a role's inbox with nobody told is indistinguishable from work
that never happened. After any `append` or `announce`, actually deliver that
printed line (a `SendMessage` to the bound session, a message to a human,
whatever this project's real channel is) before considering the handoff done.

## LEDGER.md vs. ledger/<slug>.md

Two files, deliberately disjoint, both under the inbox root:

- **`LEDGER.md`** is the cross-role event log: one line per state change
  (`append`, `pick`, `done`, `unblock`, `announce`), append-only, this tool's
  only writer. Every clause is capped at ~200 characters before the write, so
  a single `File.open(path, "a")` stays a safe atomic append even under
  concurrent writers; a longer narrative belongs in the item body, not the
  ledger line.
- **`ledger/<slug>.md`** is a per-plan phase table, hand-maintained by whoever
  is running that plan, never written by this tool. An event goes in
  `LEDGER.md`; a plan's own phase state goes in `ledger/<slug>.md`. Do not
  conflate the two or point automation at the wrong one.

## Hooks

Once a project's root has a `roster.json`, two hooks activate automatically
and need no invocation:

- **UserPromptSubmit** (`inbox_prompt_hook.rb`): prints the bound role's
  pending count and item list once per change, using `bind`'s per-session
  role first and a transcript-title heuristic (built from the roster's actual
  roles, never a hardcoded list) only as a fallback. Prints nothing when
  neither resolves, and nothing a second time for an unchanged list.
- **SessionEnd** (`inbox_session_end.rb`): commits the inbox root when it is a
  dirty git repo, silently, on every session end. That local history is
  forensics for a lost item, not a backup strategy.

Both hooks no-op completely, printing and doing nothing, for any project whose
resolved root has no `roster.json` -- there is nothing to opt out of.
