---
name: pst:rebase
description: Rebase current branch onto base, auto-resolve conflicts, remove Drizzle migrations from the feature branch, and force-push.
argument-hint: "[base-branch] [--no-push] [--dry-run] [--skip-typecheck] [--yolo]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, AskUserQuestion
---

# Rebase & Clean Drizzle Migrations

Rebase the current feature branch onto a target base branch, automatically resolve conflicts where possible, remove any Drizzle database migration files that are not present on the base branch, and force-push the result. The user will regenerate migrations manually after the rebase using Drizzle Kit.

---

## Input

<arguments> #$ARGUMENTS </arguments>

**Parse arguments:**

- `<base-branch>` -- explicit branch to rebase onto (e.g., `main`, `develop`, `origin/main`)
- `--no-push` -- skip the final `git push --force-with-lease`
- `--dry-run` -- analyze what would happen without modifying anything
- `--skip-typecheck` -- skip the Phase 3.25 post-rebase typecheck gate. Content-preservation logging still runs. Use only when the project has no typecheck script or the script is known to be broken on the base branch too.
- `--yolo` -- acknowledge content drops and typecheck regressions and push anyway. Mirrors `--no-push` as an explicit escape hatch. The guard still logs everything; `--yolo` just downgrades the block to a loud warning.
- No arguments -- infer the base branch (see Phase 1)

---

## Phase 1 -- Determine Base Branch

Collect state and resolve the target base branch.

```bash
BRANCH=$(git branch --show-current 2>/dev/null)
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
```

| Condition                          | Action                                                                |
| ---------------------------------- | --------------------------------------------------------------------- |
| `$BRANCH` is empty                 | Stop: "Not on a branch. Check out a branch first."                    |
| `$BRANCH` equals `$DEFAULT_BRANCH` | Stop: "You're on {DEFAULT_BRANCH}. Check out a feature branch first." |

**Base branch resolution order:**

1. If an explicit `<base-branch>` argument was provided, use it.
2. If the current branch has an open PR, detect its base branch:
   ```bash
   PR_BASE=$(gh pr view --json baseRefName --jq .baseRefName 2>/dev/null)
   ```
   If `$PR_BASE` is non-empty, use it.
3. Fall back to `$DEFAULT_BRANCH`.

Validate the resolved base exists on origin:

```bash
git fetch origin "$BASE_BRANCH" --quiet
```

If fetch fails, stop: "Branch `{BASE_BRANCH}` not found on origin."

**Log:**

```
Rebasing: {BRANCH} onto origin/{BASE_BRANCH}
```

---

## Phase 2 -- Pre-Rebase Snapshot

Before rebasing, record what exists so we can compare after.

### 2a. Identify Drizzle migration directories

Drizzle migrations typically live in directories matching patterns like:

- `drizzle/`
- `**/drizzle/migrations/`
- `**/migrations/`
- Any directory containing `meta/_journal.json` (Drizzle Kit's journal file)

```bash
# Find Drizzle migration directories by looking for the journal file
# Strip leading ./ so paths match git ls-tree output format
DRIZZLE_DIRS=$(find . -path '*/meta/_journal.json' -not -path '*/node_modules/*' | sed 's|/meta/_journal.json||; s|^\./||' | sort -u)
```

If no Drizzle directories are found, log: "No Drizzle migration directories detected. Skipping migration cleanup." and set `DRIZZLE_CLEANUP=false`.

### 2b. Record base branch migration state

For each Drizzle directory found, record which migration files exist on the base branch:

```bash
# Get list of migration files on the base branch for each Drizzle dir
for DIR in $DRIZZLE_DIRS; do
  BASE_MIGRATIONS=$(git ls-tree -r --name-only "origin/$BASE_BRANCH" -- "$DIR" 2>/dev/null || echo "")
done
```

Store this as the "known good" migration state from the base branch.

### 2c. Ensure clean working tree

```bash
STATUS=$(git status --porcelain 2>/dev/null)
```

If `$STATUS` is non-empty:

- Stash changes: `git stash push -m "pst:rebase auto-stash"`
- Set `STASHED=true` to restore later

### 2d. Record current HEAD and detect divergence

```bash
ORIGINAL_HEAD=$(git rev-parse HEAD)
COMMIT_COUNT=$(git rev-list --count "origin/$BASE_BRANCH..HEAD")
DIFF_STAT=$(git diff --shortstat "origin/$BASE_BRANCH..HEAD" 2>/dev/null || echo "")
```

### 2e. Baseline typecheck (for regression comparison)

Capture the feature branch's typecheck error count **before** the rebase so Phase 3.25 can diff against it. A clean pre-rebase baseline is expected -- but if the branch was already broken, we still want to detect whether the rebase made it _worse_.

```bash
# Detect package manager first (needed to construct the typecheck command)
if [ -f pnpm-lock.yaml ]; then PKG="pnpm"
elif [ -f yarn.lock ]; then PKG="yarn"
else PKG="npm"; fi

# Detect a typecheck script -- order matters (most explicit first)
PRE_TYPECHECK_CMD=""
if [ -f package.json ]; then
  if grep -qE '"typecheck"\s*:' package.json; then
    PRE_TYPECHECK_CMD="$PKG run typecheck"
  elif grep -qE '"tsc"\s*:' package.json; then
    PRE_TYPECHECK_CMD="$PKG run tsc"
  elif command -v tsc >/dev/null 2>&1 && [ -f tsconfig.json ]; then
    PRE_TYPECHECK_CMD="npx tsc --noEmit"
  fi
elif [ -f pyproject.toml ] && command -v mypy >/dev/null 2>&1; then
  PRE_TYPECHECK_CMD="mypy ."
fi

if [ -n "$PRE_TYPECHECK_CMD" ]; then
  # Run with a short timeout -- baseline only, don't block on slow typecheck
  PRE_TYPECHECK_OUT=$(timeout 180 bash -c "$PRE_TYPECHECK_CMD" 2>&1 || true)
  PRE_TYPECHECK_EXIT=$?
  PRE_TYPECHECK_ERRORS=$(echo "$PRE_TYPECHECK_OUT" | grep -cE '(error TS[0-9]+|error:)' || echo "0")
else
  PRE_TYPECHECK_ERRORS="n/a"
fi
```

Log:

```
Pre-rebase typecheck baseline: {PRE_TYPECHECK_ERRORS} error(s) [cmd: {PRE_TYPECHECK_CMD or "none detected"}]
```

If `--skip-typecheck` is set, skip this step and set `PRE_TYPECHECK_ERRORS="skipped"`.

Log:

```
Branch has {COMMIT_COUNT} commits ahead of origin/{BASE_BRANCH}
Diff stat: {DIFF_STAT}
```

**Pre-rebase divergence warning:** If `COMMIT_COUNT` is high (>10) but `DIFF_STAT` shows very few changed lines (e.g., <50 insertions+deletions), log a warning:

```
WARNING: {COMMIT_COUNT} commits but only {N} lines changed -- likely stale commits from squash-merged PRs or an un-rebased release merge.
These will be cleaned up automatically (empty commits dropped, optional squash offered).
```

**If `--dry-run`:** Print the analysis (base branch, commit count, diff stat, divergence warning if applicable, Drizzle dirs found, migrations that would be removed) and stop here.

---

## Phase 3 -- Execute Rebase

Run the rebase with automatic conflict resolution strategy.

```bash
git rebase "origin/$BASE_BRANCH" --no-autosquash --empty=drop
```

The `--empty=drop` flag automatically removes commits that become empty after replay -- this is the primary defense against squash-merged downstack PRs leaving ghost commits on the upstack branch.

### If rebase completes cleanly

Proceed to Phase 3.5.

### If rebase hits conflicts

Use a batch auto-resolve loop to handle conflicts efficiently, especially when the feature branch has many commits that overlap with upstream changes.

**Important shell compatibility notes:**

- Use `bash` (not `zsh`) for resolve scripts -- `mapfile` and other bashisms are unavailable in zsh
- Use `git status --porcelain` (not `git diff --name-only --diff-filter=U`) to detect conflicts -- the latter can miss files with special characters (parentheses, spaces) in paths
- Conflict types: `UU` = both modified, `AA` = both added, `DU` = deleted by us / modified by them, `UD` = modified by us / deleted by them

**Write and run a bash resolve script** (`/tmp/rebase-resolve.sh`):

```bash
#!/bin/bash
# Auto-resolve rebase conflicts by accepting base (ours) version
# During rebase: --ours = base branch, --theirs = feature commit being replayed
set -euo pipefail

MAX=100
AUTO_RESOLVED=0
USER_RESOLVED=0
REGENERATE_LOCKFILE=false
CONTENT_DROPS_LOG="/tmp/rebase-content-drops.log"
CONTENT_DROPS_COUNT=0
: > "$CONTENT_DROPS_LOG"

# Helper: log theirs-unique hunks that will be dropped when we accept --ours.
# This is the content-preservation guard. For each auto-accepted --ours resolve
# on a non-Drizzle, non-lockfile, non-deletion conflict, we compute what the
# feature branch (theirs) had that the base branch (ours) does NOT have, and
# record it. Phase 3.25 summarizes this before the push gate.
log_content_drop() {
  local file="$1"
  # Skip if either index stage is missing (e.g., add/add where one side is empty)
  git show ":2:$file" >/dev/null 2>&1 || return 0
  git show ":3:$file" >/dev/null 2>&1 || return 0

  # Diff ours -> theirs. Lines prefixed with "+" are present in theirs but not ours,
  # i.e. the content we are about to drop. Capture file:hunk-header:+line trios.
  local drops
  drops=$(git diff --no-color --no-index --unified=0 \
    <(git show ":2:$file") <(git show ":3:$file") 2>/dev/null \
    | awk -v f="$file" '
        /^@@/ { hunk = $0; next }
        /^\+[^+]/ { print f ":" hunk "\n  + " substr($0, 2) }
      ' || true)

  if [ -n "$drops" ]; then
    CONTENT_DROPS_COUNT=$((CONTENT_DROPS_COUNT + 1))
    {
      echo "=== $file ==="
      echo "$drops"
      echo ""
    } >> "$CONTENT_DROPS_LOG"
  fi
}

for i in $(seq 1 $MAX); do
  # Check if rebase is still in progress
  if [ ! -d .git/rebase-merge ] && [ ! -d .git/rebase-apply ]; then
    echo "REBASE_COMPLETE"
    echo "AUTO_RESOLVED=$AUTO_RESOLVED"
    echo "USER_RESOLVED=$USER_RESOLVED"
    echo "REGENERATE_LOCKFILE=$REGENERATE_LOCKFILE"
    echo "CONTENT_DROPS_COUNT=$CONTENT_DROPS_COUNT"
    echo "CONTENT_DROPS_LOG=$CONTENT_DROPS_LOG"
    exit 0
  fi

  # Detect conflicts using porcelain (handles special chars in paths)
  conflicts=$(git status --porcelain 2>/dev/null | grep -E '^(UU|AA|DU|UD) ' | sed 's/^.. //' || true)

  if [ -z "$conflicts" ]; then
    GIT_EDITOR=true git rebase --continue 2>&1 || true
    continue
  fi

  echo "=== Iteration $i: Resolving $(echo "$conflicts" | wc -l | tr -d ' ') conflict(s) ==="

  while IFS= read -r f; do
    # Determine conflict type from porcelain output
    ctype=$(git status --porcelain 2>/dev/null | grep -F "$f" | head -1 | cut -c1-2)

    # 1. Drizzle migration files -- accept base or remove
    if echo "$f" | grep -qE "(drizzle|migrations)"; then
      if [ "$ctype" = "DU" ] || [ "$ctype" = "UD" ]; then
        git rm "$f" 2>/dev/null || true
      else
        git checkout --ours "$f" 2>/dev/null && git add "$f" 2>/dev/null || git rm "$f" 2>/dev/null || true
      fi

    # 2. Lock files -- accept base, regenerate later
    elif echo "$f" | grep -qE '(pnpm-lock\.yaml|yarn\.lock|package-lock\.json)$'; then
      git checkout --ours "$f" 2>/dev/null && git add "$f" 2>/dev/null || true
      REGENERATE_LOCKFILE=true

    # 3. All other files -- accept base version
    #    (Feature commits replaying onto an updated base: base already has the latest)
    else
      if [ "$ctype" = "DU" ]; then
        # File deleted on base, modified by feature -- accept deletion
        # The feature's modifications ARE being dropped here -- log them.
        log_content_drop "$f" || true
        git rm "$f" 2>/dev/null || true
      elif [ "$ctype" = "UD" ]; then
        # File modified on base, deleted by feature -- keep base version
        git checkout --ours "$f" 2>/dev/null && git add "$f" 2>/dev/null || true
      else
        # UU/AA: both modified. Accepting --ours may silently drop theirs-unique
        # hunks. Log them BEFORE resolving so Phase 3.25 can report.
        log_content_drop "$f" || true
        git checkout --ours "$f" 2>/dev/null && git add "$f" 2>/dev/null || git add "$f" 2>/dev/null || true
      fi
    fi
  done <<< "$conflicts"

  AUTO_RESOLVED=$((AUTO_RESOLVED + $(echo "$conflicts" | wc -l | tr -d ' ')))
  GIT_EDITOR=true git rebase --continue 2>&1 | tail -5
done

echo "REBASE_FAILED: Max iterations ($MAX) reached"
exit 1
```

Run it:

```bash
bash /tmp/rebase-resolve.sh
```

**If the batch loop completes** (`REBASE_COMPLETE`), proceed to Phase 3.5.

**If the batch loop fails**, fall back to **manual per-file resolution** for the stuck commit:

For each conflicted file, read the conflict markers and attempt intelligent resolution:

1. **If one side is a strict superset** (base added lines the feature didn't touch): accept the superset
2. **If both sides modified the same lines differently**:
   - If the intent is clear and non-contradictory: combine them
   - If ambiguous: use AskUserQuestion:

     ```
     Conflict in {file}:{lines}

     BASE (upstream) version:
     {base side}

     FEATURE (your branch) version:
     {feature side}

     How should this be resolved? (Enter 'base', 'feature', or paste the desired code)
     ```

After resolving, `git add "$FILE"` and `GIT_EDITOR=true git rebase --continue`, then re-run the batch loop for remaining commits.

### If rebase is unrecoverable

If after reasonable attempts (3 retries of conflict resolution per file), the rebase cannot proceed:

```bash
git rebase --abort
```

Stop with: "Rebase aborted -- unable to automatically resolve conflicts. Manual intervention required."

If we stashed changes earlier, restore them: `git stash pop`

---

## Phase 3.5 -- Post-Rebase Bloat Detection

After the rebase completes (with empty commits already dropped by `--empty=drop`), check whether the remaining commit history is proportionate to the actual changes.

### 3.5a. Gather post-rebase metrics

```bash
POST_COMMIT_COUNT=$(git rev-list --count "origin/$BASE_BRANCH..HEAD")
# Extract total lines changed (insertions + deletions)
LINES_CHANGED=$(git diff --numstat "origin/$BASE_BRANCH" 2>/dev/null | awk '{s+=$1+$2} END {print s+0}')
# Count files changed
FILES_CHANGED=$(git diff --name-only "origin/$BASE_BRANCH" 2>/dev/null | wc -l | tr -d ' ')
```

### 3.5b. Detect bloat scenarios

**Scenario A -- Redundant commits survived empty-drop:** If `POST_COMMIT_COUNT` > `COMMIT_COUNT * 0.8` AND `LINES_CHANGED` < `POST_COMMIT_COUNT * 10`, commits may be functionally redundant even though they're not empty (e.g., they re-apply changes already on the base with minor diffs). This happens when development was merged to production and the branch was based on a stale development.

**Scenario B -- Commit/change ratio is extreme:** If `POST_COMMIT_COUNT` > 5 AND `LINES_CHANGED` / `POST_COMMIT_COUNT` < 10 (fewer than 10 lines changed per commit on average), the history is bloated.

**Scenario C -- Many commits, tiny diff:** If `POST_COMMIT_COUNT` > 10 AND `LINES_CHANGED` < 50, this is almost certainly a stale-base or squash-merge artifact.

### 3.5c. Offer auto-squash

If any bloat scenario is detected:

```
BLOAT DETECTED: {POST_COMMIT_COUNT} commits but only {LINES_CHANGED} lines changed across {FILES_CHANGED} files.

Root cause is likely one of:
  1. Downstack PR(s) were squash-merged -- their individual commits are now redundant
  2. A release merge (e.g., development -> production) included your base commits,
     and the branch wasn't rebased onto the updated base before continuing work

Recommendation: Squash into a single commit to produce a clean PR.
```

Use AskUserQuestion:

```
Squash {POST_COMMIT_COUNT} commits into one? (Y/n)
```

**If yes (default):**

```bash
# Soft-reset to the merge base, then recommit all changes as one
git reset --soft "origin/$BASE_BRANCH"
# Stage everything (the reset preserves changes in the index)
git add -A
```

Then use AskUserQuestion to get a commit message, pre-filling with the original branch name as a suggestion:

```
Commit message for the squashed commit?
(Suggestion: {BRANCH_NAME converted to title case, e.g., "feat/add-user-profile" -> "Add user profile"})
```

```bash
git commit -m "$(cat <<'EOF'
{USER_MESSAGE}

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

Log:

```
Squashed {POST_COMMIT_COUNT} commits into 1
```

**If no:** Proceed without squashing. Log: "Keeping {POST_COMMIT_COUNT} commits as-is."

### 3.5d. Log dropped commits

Report how many commits were dropped by `--empty=drop`:

```bash
DROPPED=$((COMMIT_COUNT - POST_COMMIT_COUNT))
```

If `DROPPED` > 0:

```
Dropped {DROPPED} empty commit(s) (from squash-merged PRs or duplicate cherry-picks)
```

---

## Phase 4 -- Remove Drizzle Migrations

After the rebase completes successfully, remove any Drizzle migration files that are NOT present on the base branch. This ensures the feature branch carries zero Drizzle migrations -- the user will regenerate them manually.

**Skip if `DRIZZLE_CLEANUP=false`.**

### 4a. Identify migrations to remove

For each Drizzle directory:

```bash
# Get all migration files currently in the working tree
CURRENT_MIGRATIONS=$(find "$DIR" -type f | sort)

# Get migration files that exist on the base branch
BASE_MIGRATIONS=$(git ls-tree -r --name-only "origin/$BASE_BRANCH" -- "$DIR" 2>/dev/null | sort)

# Files to remove = current - base (files not on base branch)
REMOVE_LIST=$(comm -23 <(echo "$CURRENT_MIGRATIONS") <(echo "$BASE_MIGRATIONS"))
```

This catches:

- Migrations that were on our branch before the rebase (our own feature migrations)
- Migrations that somehow got introduced during the rebase from upstream
- Any migration files not present in the base branch's version of the directory

### 4b. Also clean up the Drizzle journal

The `meta/_journal.json` file tracks migration entries. After removing migration files, the journal must be reset to match the base branch version:

```bash
for DIR in $DRIZZLE_DIRS; do
  JOURNAL="$DIR/meta/_journal.json"
  if [ -f "$JOURNAL" ]; then
    # Restore the base branch version of the journal
    git checkout "origin/$BASE_BRANCH" -- "$JOURNAL" 2>/dev/null || true
  fi

  # Also restore meta/_snapshot.json if it exists
  SNAPSHOT="$DIR/meta/_snapshot.json"
  if [ -f "$SNAPSHOT" ]; then
    git checkout "origin/$BASE_BRANCH" -- "$SNAPSHOT" 2>/dev/null || true
  fi
done
```

### 4c. Remove the files

```bash
for FILE in $REMOVE_LIST; do
  rm -f "$FILE"
done
```

Remove any empty directories left behind:

```bash
for DIR in $DRIZZLE_DIRS; do
  find "$DIR" -type d -empty -delete 2>/dev/null || true
done
```

### 4d. Commit the cleanup

If any files were removed or journals were reset:

```bash
git add -A -- $DRIZZLE_DIRS
git commit -m "$(cat <<'EOF'
Remove Drizzle migrations from feature branch

Migrations removed after rebase -- will be regenerated via Drizzle Kit.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

Log:

```
Removed {N} Drizzle migration file(s) from {DIR(s)}
```

If no files needed removal, log: "No Drizzle migration cleanup needed."

---

## Phase 5 -- Regenerate Lock File

**Skip if `REGENERATE_LOCKFILE` is not set.**

If a lock file conflict was resolved by accepting the base version, regenerate it to ensure consistency with the feature branch's `package.json`:

```bash
# Detect package manager
if [ -f pnpm-lock.yaml ]; then
  pnpm install --frozen-lockfile=false
elif [ -f yarn.lock ]; then
  yarn install
elif [ -f package-lock.json ]; then
  npm install
fi
```

If the install changes the lock file:

```bash
git add pnpm-lock.yaml yarn.lock package-lock.json 2>/dev/null
git commit -m "$(cat <<'EOF'
Regenerate lock file after rebase

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

## Phase 6 -- Restore Stash

If `STASHED=true`:

```bash
git stash pop
```

If the stash pop conflicts, warn the user: "Your stashed changes conflict with the rebased branch. Run `git stash show` to review and `git stash pop` to manually resolve."

---

## Phase 6.5 -- Pre-Push Safety Gate (Content Preservation + Typecheck)

The auto-resolve loop in Phase 3 accepts `--ours` (base) for every non-Drizzle, non-lockfile conflict. That is mechanically correct but **semantically unsafe**: if the feature branch added net-new content in a file that also changed on the base, the `--ours` resolve silently discards that content. This phase catches the regression before it's pushed.

**Concrete failure mode (the incident that motivated this gate):** FaithBase PR #38 (`nc/02-cost-cap-rate-limit-primitive`) added a new `llmCostLedger` table and `by_org_and_time` index to `convex/schema.ts`. When the skill rebased onto `main`, `convex/schema.ts` conflicted because `main` had unrelated schema changes. The loop accepted `--ours` -- `main`'s `schema.ts` -- silently dropping the new table and index. The rebase was pushed; 7 typecheck errors surfaced only during later code review.

The gate has two layers: **content-preservation log** (pre-resolution telemetry, already populated by Phase 3) and **post-rebase typecheck** (did we break the build?).

### 6.5a. Report content drops

If `CONTENT_DROPS_COUNT` > 0, surface the log:

```
CONTENT DROPS: Phase 3 accepted --ours on {CONTENT_DROPS_COUNT} file(s) with
theirs-unique content. The feature branch's additions in these files were
DISCARDED in favor of the base branch's version.

Sample drops (first 40 lines of /tmp/rebase-content-drops.log):
{head -n 40 /tmp/rebase-content-drops.log}

Full log: /tmp/rebase-content-drops.log
```

If `CONTENT_DROPS_COUNT` = 0, log: `Content preservation: no theirs-unique hunks were discarded during auto-resolve.`

### 6.5b. Post-rebase typecheck

**Skip if `--skip-typecheck`** or if `PRE_TYPECHECK_CMD` was empty in Phase 2e. Log `Typecheck gate: skipped ({reason})` and jump to 6.5c.

Run the same typecheck command captured in Phase 2e:

```bash
POST_TYPECHECK_OUT=$(timeout 300 bash -c "$PRE_TYPECHECK_CMD" 2>&1 || true)
POST_TYPECHECK_EXIT=$?
POST_TYPECHECK_ERRORS=$(echo "$POST_TYPECHECK_OUT" | grep -cE '(error TS[0-9]+|error:)' || echo "0")
```

Compute the regression delta:

```bash
if [ "$PRE_TYPECHECK_ERRORS" = "n/a" ] || [ "$PRE_TYPECHECK_ERRORS" = "skipped" ]; then
  TYPECHECK_REGRESSIONS="unknown (no baseline)"
else
  TYPECHECK_REGRESSIONS=$((POST_TYPECHECK_ERRORS - PRE_TYPECHECK_ERRORS))
fi
```

Log the result:

```
Post-rebase typecheck: {POST_TYPECHECK_ERRORS} error(s) (baseline: {PRE_TYPECHECK_ERRORS}, delta: {+N | -N | 0})
```

If the delta is positive (regressed), print the first 30 lines of `POST_TYPECHECK_OUT` so the user sees which errors are new.

### 6.5c. Decide: block, warn, or pass

Classify the run:

| Condition                                                               | Classification |
| ----------------------------------------------------------------------- | -------------- |
| `CONTENT_DROPS_COUNT` = 0 AND `TYPECHECK_REGRESSIONS` <= 0              | **clean**      |
| `CONTENT_DROPS_COUNT` > 0 AND `TYPECHECK_REGRESSIONS` <= 0              | **warn**       |
| `TYPECHECK_REGRESSIONS` > 0 (regardless of content drops)               | **blocker**    |
| `TYPECHECK_REGRESSIONS` = "unknown (no baseline)" AND content drops > 0 | **warn**       |

**clean:** Log `Safety gate: clean, proceeding to push.` and continue to Phase 7.

**warn:** Print the full content-drops log head and ask:

> Phase 3 auto-resolve dropped content from {CONTENT_DROPS_COUNT} file(s).
> Typecheck regressions: {TYPECHECK_REGRESSIONS}.
>
> The log is at `/tmp/rebase-content-drops.log`. Review before deciding.
>
> 1. Inspect the log and proceed (I have reviewed the drops)
> 2. Abort before push (run `git reset --hard {ORIGINAL_HEAD}` to restore)
> 3. Skip push but keep the rebased state (equivalent to `--no-push`)

Use AskUserQuestion. On option 1, set `GATE_DECISION="warn-acknowledged"` and continue to Phase 7. On option 2, run `git reset --hard "$ORIGINAL_HEAD"` and stop. On option 3, set `PUSH_BLOCKED=true` and skip Phase 7.

**blocker:** Print the typecheck output and the content-drops log head. Ask:

> BLOCKED: Rebase introduced {TYPECHECK_REGRESSIONS} new typecheck error(s). This
> is the `--ours` content-drop failure mode -- Phase 3 likely accepted base versions
> of files where the feature branch added net-new content.
>
> First 30 lines of new errors:
> {POST_TYPECHECK_OUT head}
>
> Content drops logged: {CONTENT_DROPS_COUNT} file(s) at /tmp/rebase-content-drops.log
>
> 1. Abort and reset to pre-rebase HEAD ({ORIGINAL_HEAD}) -- recommended
> 2. Skip push, keep the broken rebased state for manual inspection
> 3. Push anyway (requires `--yolo` flag; without it this option is hidden)

If `--yolo` is set, option 3 is available and chooses it passes with a loud warning: `WARNING: --yolo pushed through a typecheck regression. CONTENT_DROPS={N}, REGRESSIONS={N}.` and sets `GATE_DECISION="yolo"`. Without `--yolo`, option 3 is not offered. Default to option 1 on ambiguous input.

**Non-interactive fallback:** If AskUserQuestion is unavailable in the execution environment (e.g., skill invoked in a fully autonomous pipeline), behavior is:

- **clean:** continue
- **warn:** continue with `GATE_DECISION="warn-autoproceed"` and include the drops log path in the Output Contract
- **blocker:** if `--yolo` is set, push with a warning. Otherwise stop with `Pre-push safety gate blocked the push. Content drops: {N}. Typecheck regressions: {N}. Re-run with --yolo to override or manually fix.`

Set `PUSH_BLOCKED=true` on any stop/skip path so the Output Contract reflects it.

---

## Phase 7 -- Push

**Skip if `--no-push` or `PUSH_BLOCKED=true`.**

```bash
git push --force-with-lease origin "$BRANCH"
```

If push fails, stop with the error. Suggest checking if someone else pushed to the branch.

---

## Output Contract

Always print this block at the end:

```
--- REBASE RESULT ---
branch: {BRANCH}
base: origin/{BASE_BRANCH}
commits-before: {N}
commits-after: {N}
empty-commits-dropped: {N}
squashed: {yes (N -> 1) | no}
lines-changed: {N}
conflicts-resolved: {N auto-resolved} auto, {N user-resolved} manual
content-drops-flagged: {N} (log: /tmp/rebase-content-drops.log)
typecheck-baseline: {N | n/a | skipped}
typecheck-post-rebase: {N | skipped}
typecheck-regressions: {N | unknown (no baseline) | skipped}
safety-gate: {clean | warn-acknowledged | warn-autoproceed | yolo | blocked}
push-blocked: {yes | no}
drizzle-migrations-removed: {N}
drizzle-dirs: {dir1, dir2, ... | none}
lockfile-regenerated: {yes | no}
stash: {restored | not needed}
pushed: {yes | skipped (--no-push) | skipped (--dry-run) | skipped (safety gate)}
--- END REBASE RESULT ---
```

---

## Error Handling

| Condition                                      | Action                                                                                           |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| On default branch                              | Stop with message                                                                                |
| Base branch not found                          | Stop: "Branch `{BASE_BRANCH}` not found on origin."                                              |
| `git` not available                            | Stop with message                                                                                |
| Rebase unrecoverable                           | Abort rebase, restore stash, stop with message                                                   |
| Push fails                                     | Stop with error, do not lose local state                                                         |
| Stash pop conflicts                            | Warn user, leave stash intact                                                                    |
| No Drizzle dirs found                          | Skip migration cleanup silently                                                                  |
| `gh` not available                             | Warn (cannot detect PR base), fall back to default branch                                        |
| Lock file regeneration fails                   | Warn but continue                                                                                |
| No typecheck script detected (Phase 2e)        | Set `PRE_TYPECHECK_ERRORS="n/a"`, skip 6.5b typecheck, continue. Content-drop log still runs.    |
| Typecheck regression detected without `--yolo` | Block push via Phase 6.5c, print new errors + drops log, require manual decision                 |
| Typecheck regression with `--yolo`             | Push with a loud warning, record `safety-gate: yolo` in Output Contract                          |
| Content drops with no typecheck regression     | Warn, require acknowledgement (or auto-proceed in non-interactive mode), record drops log path   |
| Typecheck times out (>300s in Phase 6.5b)      | Treat as `unknown (no baseline)`, apply `warn` classification if content drops > 0 else continue |
