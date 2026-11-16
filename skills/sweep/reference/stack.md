# cf:sweep stack mode: the loop

Stack mode lands a batch or stack of PRs strictly one at a time. The current
PR is always the first one not merged. The store is a cache; gh is the truth.

Report, land, and auto share this per-PR loop: every sweep mode lands one PR
at a time at the head of line (`skills/sweep/SKILL.md`, One PR at a time).
Stack mode differs only in where the order comes from.

## Invocations

Forms: `/cf:sweep stack <plan_dir | #a #b ...>`, `/cf:sweep stack resume`,
`/cf:sweep stack status`.

- `/cf:sweep stack <plan_dir>`: one PR per plan phase, in phase order. Slug is
  the plan directory name, source `plan`.
- `/cf:sweep stack #a #b ...`: an explicit PR list, in the order given. Slug
  is `prs-<first>-<last>`, source `list`.
- `/cf:sweep stack resume`: re-derive state from gh and continue at the
  current PR.
- `/cf:sweep stack status`: print the store merged with live gh state (each
  PR's state, base, head SHA, checks), plus the count of judged decisions and
  the plan.md path. Read-only.

Start a stack with:

```
ruby ~/.claude/cf/bin/stack_store.rb claim <slug> --source stack
ruby ~/.claude/cf/bin/stack_store.rb init <slug> --repo <o/r> --source plan|list \
  --mode <merge_ready|admin_bypass|yolo> [--plan-dir DIR] --pr N:URL:HEAD:SHA ...
```

`claim` takes the repo's one ACTIVE queue; if another queue (a sweep or
another stack) holds it, stop and name the holder. `init` refuses without the
claim. `init` also writes the `stack-<slug>` ctx pointer, so SessionStart surfaces
a paused stack and offers `/cf:sweep stack resume`.

## Executor lease

`LEASE` in the same directory as ACTIVE says which run is executing the queue:
`stack_store.rb lease <slug> --session <id> [--pid <pid>]`. It is exclusive
even for the same slug, so two runs of one queue never execute at once; only
the same session re-acquires its own lease. Takeover only when the holder's
pid is gone on this host or its heartbeat is older than 900 seconds; otherwise
it exits non-zero with `{"error":"leased"}` and the run stops. The check and
the replacement run under one lock, so two takeovers never both win. Run
`stack_store.rb heartbeat <slug> --session <id>` at each step of the per-PR
loop, and `unlease <slug> --session <id>` on completion, pause, or abandon;
it frees only this session's lease, never a successor's. While a PR waits on
the maintainer, `stack_watch.rb --lease <slug> --session <id>` heartbeats on
every poll, and `--baseline-sha <old_head_sha>` makes a head that moved
before the watcher started read as a foreign push (exit 4).

Claim and lease are published atomically (temp file, fsync, `link(2)`, which
fails when the name exists), so neither is ever read half written. An empty or
unparseable file reads as held, never as free. `stack_store.rb release <slug>
--stale` clears a claim that has no record and no live lease holder, and
refuses otherwise.

Read the merge mode with `merge_mode_store.rb`. Under local only, stack mode
does not run: say so and stop.

## Per-PR loop

1. **Re-derive.** `gh pr view <n> --json state,baseRefName,headRefName,headRefOid,mergedAt`.
   Never trust the store alone. A PR already merged advances; a PR closed
   unmerged escalates (the user decides drop or reopen).
2. **Rebase.** Resolve trunk once per run, by the Scope rule in
   `skills/sweep/SKILL.md`, and use it everywhere below as `<trunk>`.
   `git fetch origin`. If the parent PR squash merged, run
   `git rebase --onto origin/<trunk> <parent-old-head> <head>`, which drops
   the parent's commits, then `gh pr edit <n> --base <trunk>`.
   `<parent-old-head>` is the parent's own final pre-merge head: the
   `old_head_sha` recorded on the parent's entry just before the parent
   merged, never a SHA captured at the start of the run. If it is unknown
   (store lost), take it from `gh pr view <parent> --json headRefOid` (GitHub
   keeps a merged PR's last head); if the parent is gone, fall back to
   `git rebase origin/<trunk>` and let empty commits drop. Resolve conflicts
   yourself, re-run the test command, and `git push --force-with-lease`.
   If tests stay red after one fix pass, pause and escalate with the conflict
   summary. The same cut applies at any depth: each child rebases onto its
   own parent's final head, one PR at a time.
3. **Prepare.** Invoke cf:drive quick with "nested under cf:sweep stack". It
   skips cf:plan and runs no approval review. Read its `drive-result` block:
   CI fixed and green, cf:resolve-threads ran, `pendingReplies` posted after
   the push.
4. **Recurrence.** If resolve-threads returned a non-null `plan`:
   - merge ready: `stack_store.rb pause <slug> plan_interview`, tell the user
     to run `/cf:plan` with the seeded goal, and stop. Resume continues after
     the plan lands.
   - admin bypass: run `/cf:plan --judge` on the seeded goal, record each
     judged item with `stack_store.rb judged <slug> <text>`, and continue.
4b. **Visuals.** Only for a stack started from a plan dir whose `## Visuals`
   list is not empty, once this PR's CI is green and it is CLEAN. With
   `<k>` this PR's phase number (its position in the stack) and `<first>`
   the stack's first PR number:
   - Run `ruby ~/.claude/cf/bin/plan_visuals.rb check <plan_dir> --pr <n>
     --phase <k>`. Exit 0 or 2 (match or inconclusive) goes straight to the
     post.
   - Exit 1 (drift): redraw each drifted visual the way cf:plan step 7a
     draws it (cf:diagram or cf:chart, lint, render light and dark PNGs),
     then rewrite the manifest with `plan_visuals.rb manifest <plan_dir>
     --drawn-against pr:<n>@<head sha>`. A visual whose redraw still fails
     lint is posted as an omission with `--omit <name>='redraw failed'`.
   - Post with `ruby ~/.claude/cf/bin/plan_visuals.rb post <plan_dir> --pr
     <n> --phase <k> --first-pr <first> --require-settled`. Exit 4 (not
     settled) waits and retries; exit 3 is reported and does not block the
     hand off.
5. **Hand off** by merge mode, below. Just before the hand off, record this
   PR's final head with `stack_store.rb set-pr <slug> <n> old_head_sha=<sha>`
   (`gh pr view <n> --json headRefOid`); the child cuts at it after the merge.
   Re-record after any later push to this PR.
6. **Advance.** Confirm with `gh pr view <n> --json state,mergedAt` that the
   PR merged, then `stack_store.rb advance <slug> --expect <n>`; the next PR
   rebases onto the fresh trunk. After the last PR, `stack_store.rb release
   <slug>` and report what landed.

## Hand-off by merge mode

### merge ready

Post `https://github.com/<owner>/<repo>/pull/<n>` in chat, then start the
watcher with Bash `run_in_background: true`:

```
ruby ~/.claude/cf/bin/stack_watch.rb --pr <n> --repo <o/r> --expect-sha <head>
```

It polls every 60s for up to 24h. A user "merged #N" message is a second
signal and advances the same as exit 0.

| Exit | Event | Action |
|---|---|---|
| 0 | merged | Advance. |
| 2 | setup error | Fix the invocation (gh missing, bad args) and re-arm. |
| 3 | closed unmerged | Escalate. |
| 4 | foreign push | Back to step 3, then re-arm. |
| 5 | new review thread | Back to step 3, then re-arm. |
| 6 | red check | Back to step 3, then re-arm. |
| 7 | timeout | Pause and report. |

Pass every SHA the stack itself pushes as `--expect-sha`, so our own push
never reads as a foreign one.

### admin bypass

Read `ChangePolicy.for_repo(root)`.

- If `!admin_bypass_allowed?`, escalate to the user: reconfigure CHANGE.md for
  this repo, or help run the lanes in local Docker. Never set
  `CF_ALLOW_UNGATED_MERGE` and never run `change_override.rb`.
- If `ChangeGateCheck.required?(policy, base: '<trunk>', kind: :pr_merge)`,
  ask the SHA gate record for the current head SHA directly:
  `ChangeGateCheck.new(sha: <head>, profile: <base profile>, apps:
  ChangeGateCheck.required_apps(root, <rule apps>)).satisfied?`. This is the
  same record `change_merge_guard.rb` checks. Do not use
  `change_run.rb gate-status --ref <sha>`: a bare SHA matches no promotion
  rule, so it reports success without a recorded pass. If not satisfied, run
  cf:change on the head. Exit 0 passes. Exit 2 escalates at once. Exit 1:
  make one attributable fix and re-run, else escalate. Every rebase
  invalidates the gate, so check it against the current head SHA.
- `change_policy.gate.require_on` is available from spec 0.14.0. When it is
  absent the gate applies to every merge (`every_merge`); `promotion` skips
  the gate for a PR merge into trunk.
- Then `gh pr merge <n> --squash --admin`.

### yolo

No PRs are opened. Rebase the branch onto origin/<trunk>, run the tests,
then `git push origin HEAD:<trunk>` and move to the next branch. A rejected push
(protected trunk) escalates; never force.

## Escalate versus pause

Escalate (stop and ask the user): a PR closed unmerged, cf:change exit 2 or a
CHANGE.md block on admin bypass, a cf:change failure that one fix does not
clear, a rejected yolo push. Pause (`stack_store.rb pause`, resumable): a
plan interview under merge ready, a watcher timeout, red tests after a
conflict fix. The store and the ctx pointer survive a dead watcher or an ended
session; resume re-derives from gh.
