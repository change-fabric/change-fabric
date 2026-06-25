---
name: pst:prune
description: After a PR merges, fast-forward the trunk to origin and prune merged branches and worktrees, locally and on the remote, so the clone is clean. Never deletes unmerged or dirty work without an explicit AskUserQuestion approval, and never deletes a remote branch without one.
---

# PST Prune

Return the local clone, and the remote, to a clean state on the latest trunk
after a PR lands.

Triggered two ways:

- **Manually:** `/pst:prune`.
- **Discerned:** when the turn establishes that a PR or branch just merged (the
  user says "I merged #N", or a PR you were tracking now reads merged), run this
  without being asked. Confirm the merge is real before pruning, do not infer it
  from an open PR. A `UserPromptSubmit` hook (`prune_remind.rb`) surfaces this
  skill when the prompt reads as a completed merge; it is advisory, the guards
  below still apply.

Two rules govern every deletion:

1. **Never discard unmerged or uncommitted work on your own judgment.** Local
   pruning is applied only to branches and worktrees that are both clean and
   fully merged into the trunk. Anything else is surfaced, not removed.
2. **Never delete a remote branch without explicit approval.** A
   `git push origin --delete` is destructive and shared. Always get an
   `AskUserQuestion` yes first, with a written justification, even when the
   branch is fully merged.

Honor the session merge mode. Under Local only, do not push at all (remote
pruning is off); the remote half is skipped and only local pruning runs.

## Trunk

Resolve the trunk from the remote default, do not assume `main`:

```bash
git remote set-head origin -a >/dev/null 2>&1
TRUNK=$(git symbolic-ref --short refs/remotes/origin/HEAD | sed 's#^origin/##')
```

## Workflow

1. **Survey.** `git worktree list`, `git branch -vv`, `git branch -r`,
   `git status -sb`. Note the current branch and which worktree is the host.
2. **Fetch.** `git fetch --prune origin`. This drops tracking refs for remote
   branches already deleted on the server (a merge often auto-deletes the head
   branch), and refreshes the merge checks below. Pruning a stale tracking ref
   is not a remote deletion and needs no approval.
3. **Classify** every local branch, every worktree, and every remote branch
   other than the trunk:
   - *Dirty worktree:* `git status` not clean -> rogue.
   - *Unmerged branch* (local or remote): `git rev-list --count origin/$TRUNK..<ref>`
     > 0 -> rogue.
   - *Clean and merged:* working tree clean and zero unmerged commits -> prunable.
4. **Fast-forward the trunk.** Switch the host worktree to `$TRUNK`, then
   `git pull --ff-only origin $TRUNK`. If the fast-forward is refused, the local
   trunk has diverged: treat it as rogue and ask.
5. **Prune safe local work.** `git worktree prune` to clear stale metadata, then
   `git worktree remove <path>` for each non-host worktree classified prunable,
   and `git branch -d <branch>` for each prunable branch (lowercase `-d` refuses
   an unmerged branch as a backstop).
6. **Prune the remote, with approval.** For remote branches other than the trunk
   that still exist after step 2, do not delete silently. Use `AskUserQuestion`
   (see Asking) and only on an explicit yes run
   `git push origin --delete <branch>`.
7. **Re-prune tracking refs.** `git fetch --prune origin` if anything changed.
8. **Report.** Show the final `git branch`, `git branch -r`,
   `git worktree list`, and `git status -sb`, and list anything left in place
   because it was rogue or declined.

## Asking

Use `AskUserQuestion` in two situations. Name the specific branch or worktree
and the evidence, so the choice is informed. Other agents may own a branch or
worktree you see, which is why these are surfaced rather than removed.

**Rogue work** (unmerged commits, or a dirty worktree). Per item, offer at
least:

- **Keep it** (leave it untouched).
- **Delete anyway** - only on explicit confirmation, since it discards work
  (`git branch -D`, `git worktree remove --force`, and for a remote branch
  `git push origin --delete`).

**Destructive remote deletion** (deleting any `origin/<branch>`, even a merged
one). State the justification before asking, for example "origin/feature-x is
fully merged into $TRUNK as of PR #N, so deleting it on the remote discards
nothing." Offer:

- **Delete on the remote** (`git push origin --delete <branch>`).
- **Keep it.**

Do not run any `git push ... --delete` until the matching question returns an
explicit approval.
