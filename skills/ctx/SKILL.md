---
name: pst:ctx
description: Capture, recall, and list durable project context in the shim-owned .ctx store, a git-backed set of classed markdown docs kept outside any project's own source control and keyed by working directory. Use to record contracts, plans, client notes, and decisions that must persist across sessions and devices, distinct from the harness auto-memory.
---

# PST Context Store

A per-project store of durable context (`.ctx`) that lives at
`~/.claude/pst/ctx/<dashed-cwd>/`, outside the project's own git. It is shim
owned and git backed, distinct from harness auto-memory. Each doc is markdown
with a YAML frontmatter block and belongs to one class:

- `truth` - durable facts that never auto-expire (contracts, decisions, PRDs).
- `active` - in-flight work until done or superseded (plans, tasks, client threads).
- `ephemeral` - scratch with a ttl (throwaway working notes).

See `reference.md` for the full frontmatter schema and class taxonomy.

**Trigger:** `/pst:ctx`, or when the user asks to remember, record, or look up
project context (a plan, a contract, a client thread, a decision) that should
outlive the session. For a single non-obvious fact about the codebase, prefer
harness auto-memory; `.ctx` is for the larger durable artifacts above.

The store commits locally on every write. Pushing to the NAS git remote and
cross-device sync arrive in a later phase, so a write here is always safe and
offline.

## Verbs

Run the store CLI at `~/.claude/pst/bin/ctx_store.rb`.

### capture

Write a new doc. Pick the class deliberately, give a slug name
(`[a-z0-9-]`) and a one-line third-person description. The body is read from
stdin. Pass the current session id when known.

```bash
printf '%s' "Body of the note, one concern per doc." | \
  ruby ~/.claude/pst/bin/ctx_store.rb capture \
    --name ctx-system-plan --class active \
    --desc "Implementation plan for the pst:ctx store, in flight." \
    --session "$SESSION_ID"
```

An `ephemeral` doc requires `--ttl` (a day count like `14d`); a `truth` doc must
not carry one. Capture refuses an unknown class, a bad name, or an empty
description rather than writing a malformed doc.

### recall

Print one doc by name.

```bash
ruby ~/.claude/pst/bin/ctx_store.rb recall ctx-system-plan
```

### list

Show the live docs, optionally filtered.

```bash
ruby ~/.claude/pst/bin/ctx_store.rb list --class active --status active
```

`INDEX.md` at the store root holds the same one-line-per-doc summary and is
regenerated on every write; read it for a cheap overview.

## Authoring rules

- One concern per doc: a single contract, plan, client thread, or decision, not
  a grab-bag. Split a long note into linked sub-docs.
- Keep a doc body under 200 lines (300 is the hard ceiling); push detail into a
  separate doc rather than letting one grow without bound.
- The class in frontmatter is authoritative and must match the directory the doc
  sits in. The store enforces this on write.
