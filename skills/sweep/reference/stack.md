# cf:sweep stack mode: the loop

Stack mode lands a batch or stack of PRs strictly one at a time. The current
PR is always the first one not merged. The store is a cache; gh is the truth.

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
ruby ~/.claude/cf/bin/stack_store.rb init <slug> --repo <o/r> --source plan|list \
  --mode <merge_ready|admin_bypass|yolo> [--plan-dir DIR] --pr N:URL:HEAD:SHA ...
```

`init` also writes the `stack-<slug>` ctx pointer, so SessionStart surfaces
a paused stack and offers `/cf:sweep stack resume`.

Read the merge mode with `merge_mode_store.rb`. Under local only, stack mode
does not run: say so and stop.

## Per-PR loop

1. **Re-derive.** `gh pr view <n> --json state,baseRefName,headRefName,headRefOid,mergedAt`.
   Never trust the store alone. A PR already merged advances; a PR closed
   unmerged escalates (the user decides drop or reopen).
2. **Rebase.** `git fetch origin`. If the parent PR squash merged, run
   `git rebase --onto origin/main <parent-old-head> <head>`, which drops the
   commits the squash made empty, then `gh pr edit <n> --base main`. If the
   parent's old head is unknown (store lost), take it from
   `gh pr view <parent> --json headRefOid`; if the parent is gone, fall back
   to `git rebase origin/main` and let empty commits drop. Resolve conflicts
   yourself, re-run the test command, and `git push --force-with-lease`.
   Record the new head with `stack_store.rb set-pr <slug> <n> old_head_sha=<sha>`
   for the next PR. If tests stay red after one fix pass, pause and escalate
   with the conflict summary.
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
5. **Hand off** by merge mode, below.
6. **Advance.** `stack_store.rb advance <slug>`; the next PR rebases onto the
   fresh main. After the last PR, clear the store and report what landed.

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
- If `ChangeGateCheck.required?(policy, base: 'main', kind: :pr_merge)`, first
  `ruby ~/.claude/cf/bin/change_run.rb gate-status --ref <sha>`; if no pass is
  recorded, run cf:change. Exit 0 passes. Exit 2 escalates at once. Exit 1:
  make one attributable fix and re-run, else escalate. Every rebase
  invalidates the gate, so check it against the current head SHA.
- `change_policy.gate.require_on` is available from spec 0.14.0. When it is
  absent the gate applies to every merge (`every_merge`); `promotion` skips
  the gate for a PR merge into trunk.
- Then `gh pr merge <n> --squash --admin`.

### yolo

No PRs are opened. Rebase the branch onto origin/main, run the tests, then
`git push origin HEAD:main` and move to the next branch. A rejected push
(protected main) escalates; never force.

## Escalate versus pause

Escalate (stop and ask the user): a PR closed unmerged, cf:change exit 2 or a
CHANGE.md block on admin bypass, a cf:change failure that one fix does not
clear, a rejected yolo push. Pause (`stack_store.rb pause`, resumable): a
plan interview under merge ready, a watcher timeout, red tests after a
conflict fix. The store and the ctx pointer survive a dead watcher or an ended
session; resume re-derives from gh.
