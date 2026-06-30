# pst:ctx reference

Schema and taxonomy for `.ctx` docs. The SKILL.md body is the working guide;
this is the detail it defers to.

## Store layout

Keyed by the absolute cwd with every `/` turned to `-`, byte-identical across
devices because they run under the same home (pinned per device by install.rb,
so the repo never names it).

```
~/.claude/pst/ctx/<dashed-cwd>/
  INDEX.md            one line per live doc, regenerated on every write
  ROADMAP.md          the single shared roadmap doc (later phase)
  truth/              class: truth
  active/             class: active
  ephemeral/          class: ephemeral
  archive/            compacted digests of purged docs (later phase)
  .ctx-meta/
    device            this device's short hostname, stamped into originDevice
```

A doc lives at `<class>/<name>.md`. The directory and the frontmatter `class`
must agree; the store rejects a write that would break that.

## Frontmatter schema

```yaml
name:            short slug, [a-z0-9-], unique within the store
description:     one line, third person, used for the INDEX line
class:           truth | active | ephemeral
status:          active | done | superseded | archived (defaults to active)
ttl:             ephemeral only, a day count like 14d
expires:         ephemeral only, derived date, ttl applied to last_touched
review_after:    optional (truth), a day count; past it the doc is review-due
last_touched:    ISO-8601 timestamp, rewritten on every capture
originSessionId: session id that wrote the doc
originDevice:    short hostname, from .ctx-meta/device
supersedes:      optional, name of the doc this replaces
```

Validation enforced on write:

- `class` is required and one of the three.
- `truth` may not carry `ttl` or `expires`.
- `ephemeral` must carry `ttl`; `expires` is computed.
- `review_after`, if set, must be a day count.
- `status` defaults to `active`.

## Class taxonomy

- `truth` - signed contracts, architecture and client-identity decisions, PRDs.
  Never auto-expires and is never auto-removed. After a long no-touch interval
  (the doc's `review_after`, or a default of 365 days) it becomes review-due:
  prune surfaces it for a human to reconfirm (re-attest), archive, or remove, so
  a durable fact nobody has touched in a year does not bloat the store forever.
- `active` - deep-research implementation plans, standalone task lists, live
  client comms and working notes. A candidate for archival once `done` or
  `superseded`.
- `ephemeral` - throwaway scratch with an explicit ttl. A candidate for removal
  once past `expires`.

## Provenance

`last_touched`, `originSessionId`, and `originDevice` are stamped on every
capture. `originDevice` reads from `.ctx-meta/device`, written once per device
from `hostname -s` at first write, so a doc records which machine authored it
without a `hostname` call on every write.

## Worked examples

A truth doc:

```
---
name: acme-msa-2026
description: Master services agreement with the Acme client, signed 2026-03-01.
class: truth
status: active
last_touched: '2026-06-27T09:00:00-04:00'
originSessionId: 3f2a
originDevice: laptop-a
---
Scope, rate, term. The signed PDF lives elsewhere; this is the durable record.
```

An ephemeral doc:

```
---
name: remote-bootstrap-scratch
description: Throwaway notes while standing up the sync git remote.
class: ephemeral
status: active
ttl: 14d
expires: '2026-07-11'
last_touched: '2026-06-27T09:12:00-04:00'
originSessionId: 92a2
originDevice: laptop-a
---
Commands tried, what worked. Safe to expire once bootstrap lands.
```
