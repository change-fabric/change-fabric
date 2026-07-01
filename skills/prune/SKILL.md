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
   justification, even for a fully merged branch. Exception: the single case
   verified in step 7 (`CURRENT_BRANCH`, content-merged, confirmed via `gh pr
   view` against a real merged PR, never merely asserted by the human). This
   never extends to any other remote branch found in the same sweep.
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
   `git status -sb`. Note `CURRENT_BRANCH` (the branch checked out in the host
   worktree) before step 4 fast-forwards it away, and the host worktree path.
2. **Fetch:** `git fetch --prune origin` (drops tracking refs for server-deleted
   branches and refreshes merge checks; not a remote deletion).
3. **Classify:** run `ruby ~/.claude/pst/bin/branch_classify.rb $TRUNK` and act on
   its JSON, one entry per local branch other than trunk:
   - `kind: "prunable"` -> zero unmerged commits against `origin/$TRUNK`.
   - `kind: "squash_merged"` -> commits aren't literally in trunk history, but a
     tip-to-tip diff against `origin/$TRUNK` is empty, so the content already
     landed as one squashed commit. Prunable, same as any other merged branch;
     do not ask about it as rogue.
   - `kind: "rogue"` -> a dirty worktree, or unmerged commits with a real diff
     against trunk.
   - `error: "trunk_unresolved"` -> `origin/$TRUNK` does not exist locally (stale
     fetch, wrong name). Fetch and retry before trusting any classification.
4. **Fast-forward:** switch the host worktree to `$TRUNK`, `git pull --ff-only
   origin $TRUNK`. If refused, the local trunk diverged: treat as rogue and ask.
5. **Prune local:** `git worktree prune`, then `git worktree remove <path>` and
   `git branch -d <branch>` per prunable item (`-d` refuses unmerged as a backstop).
6. **Clean untracked** (per surviving worktree): `git clean -nd` to preview,
   classify (see below), then ask. Run `git clean -fd -- <paths>` only on a yes.
7. **Prune remote:** for non-trunk `origin/<branch>` still present after step 2:
   if `branch == CURRENT_BRANCH` and its classify `kind` was `prunable` or
   `squash_merged`, run `ruby ~/.claude/pst/bin/merge_confirmation.rb <branch>
   <kind>`. On `confirmed: true`, delete directly (no question); report the
   evidence (PR number, verified `MERGED`, `headRefName` match, `kind`) in the
   final report instead of a question. On `confirmed: false`, or for every
   other `origin/<branch>` (including ones incidentally merged), ask as below,
   then `git push origin --delete <branch>` only on a yes.
8. **Re-prune:** `git fetch --prune origin` if anything changed.
9. **Report:** final `git branch`, `git branch -r`, `git worktree list`,
   `git status -sb`, plus anything kept because it was rogue or declined.
10. **Ctx maintenance:** if `~/.claude/pst/bin/ctx_retention.rb` exists, run
    `ruby ~/.claude/pst/bin/ctx_retention.rb prune` for this project's context
    store. It auto-removes expired ephemeral docs; for each `needs review` item
    AskUserQuestion (Archive / Remove / Keep) before acting, and apply with
    `ctx_store.rb archive|remove <name>`; surface `structural issues` for the user
    to fix. Never touch a `truth` doc. This is the pst:ctx prune flow; its skill
    has the detail. Local-only, so it runs under every merge mode.

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
| Remote deletion of `CURRENT_BRANCH`, verified via `merge_confirmation.rb` | No question: state the evidence (PR #N, `MERGED`, `headRefName` match, `kind`), then delete |
| Remote deletion of any other `origin/<branch>` | State justification ("merged into $TRUNK as of #N, deleting discards nothing"), then Delete on remote; or Keep it |
| Untracked files | Clean the junk (`git clean -fd -- <junk>`, keepers excluded); Clean named keepers too (explicit only); or Keep everything |
