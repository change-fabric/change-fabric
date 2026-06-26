---
name: pst:prune
description: After a PR merges, fast-forward the trunk and prune merged branches and worktrees (local and remote), and optionally clear untracked junk. Protects keepers like env files with secrets. Never deletes unmerged, uncommitted, or untracked work, or any remote branch, without an explicit AskUserQuestion yes.
---

# PST Prune

Return the local clone and the remote to a clean state on the latest trunk after
a PR lands.

**Trigger:** `/pst:prune`, or unprompted when the turn confirms a PR or branch
merged ("I merged #N", or a tracked PR now reads merged). Verify the merge is
real; never infer it from an open PR. The `prune_remind.rb` hook only surfaces
the skill; these guards still apply.

## Invariants (never violate)

1. Delete local work only when it is both clean and fully merged into the trunk.
   Surface anything else; never discard it on your own judgment.
2. Never `git push origin --delete` without an AskUserQuestion yes and a written
   justification, even for a fully merged branch.
3. Never `git clean` without an AskUserQuestion yes scoped to named paths, and
   never `git clean -x`/`-X`. Plain `git clean` already skips gitignored files,
   which is where a real `.env` with secrets lives; `-x` would sweep exactly those.

Honor the session merge mode: under Local only, skip every remote step.

## Trunk

Resolve from the remote default, do not assume `main`:

```bash
git remote set-head origin -a >/dev/null 2>&1
TRUNK=$(git symbolic-ref --short refs/remotes/origin/HEAD | sed 's#^origin/##')
```

## Workflow

1. **Survey:** `git worktree list`, `git branch -vv`, `git branch -r`,
   `git status -sb`. Note the current branch and host worktree.
2. **Fetch:** `git fetch --prune origin` (drops tracking refs for server-deleted
   branches and refreshes merge checks; not a remote deletion).
3. **Classify** each branch and worktree against the trunk:
   - dirty worktree, or `git rev-list --count origin/$TRUNK..<ref>` > 0 -> rogue.
   - clean and zero unmerged commits -> prunable.
4. **Fast-forward:** switch the host worktree to `$TRUNK`, `git pull --ff-only
   origin $TRUNK`. If refused, the local trunk diverged: treat as rogue and ask.
5. **Prune local:** `git worktree prune`, then `git worktree remove <path>` and
   `git branch -d <branch>` per prunable item (`-d` refuses unmerged as a backstop).
6. **Clean untracked** (per surviving worktree): `git clean -nd` to preview,
   classify (see below), then ask. Run `git clean -fd -- <paths>` only on a yes.
7. **Prune remote:** for non-trunk `origin/<branch>` still present after step 2,
   ask, then `git push origin --delete <branch>` only on a yes.
8. **Re-prune:** `git fetch --prune origin` if anything changed.
9. **Report:** final `git branch`, `git branch -r`, `git worktree list`,
   `git status -sb`, plus anything kept because it was rogue or declined.

## Classifying untracked

From `git clean -nd`, when unsure treat as a keeper:
- **Keeper** (never in a clean command): `.env`, `.env.*`, `.envrc`, `*.pem`,
  `*.key`, `*.crt`, `*.p12`, `*.pfx`, `id_rsa*`, anything secrets-pathed, and any
  hand-authored file (config, note, script).
- **Junk:** build output and tool/OS cruft - `.DS_Store`, `Thumbs.db`, `*.log`,
  `*.tmp`, `*.swp`, `*~`, known build directories.

## Asking

Name the specific item and the evidence; another agent may own what you see.
Run nothing destructive until the matching question returns a yes.

| Situation | Options |
| --- | --- |
| Rogue work (unmerged commits or dirty worktree) | Keep it; or Delete anyway (explicit only): `git branch -D`, `git worktree remove --force`, `git push origin --delete` |
| Remote deletion of any `origin/<branch>` | State justification ("merged into $TRUNK as of #N, deleting discards nothing"), then Delete on remote; or Keep it |
| Untracked files | Clean the junk (`git clean -fd -- <junk>`, keepers excluded); Clean named keepers too (explicit only); or Keep everything |
