---
name: pst:rebase
description: Rebase current branch onto base, auto-resolve conflicts, remove Drizzle migrations from the feature branch, and force-push.
argument-hint: "[base-branch] [--no-push] [--dry-run]"
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
- No arguments -- infer the base branch (see Phase 1)

---

## Phase 1 -- Determine Base Branch

Collect state and resolve the target base branch.

```bash
BRANCH=$(git branch --show-current 2>/dev/null)
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
```

| Condition | Action |
|---|---|
| `$BRANCH` is empty | Stop: "Not on a branch. Check out a branch first." |
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

### 2d. Record current HEAD

```bash
ORIGINAL_HEAD=$(git rev-parse HEAD)
COMMIT_COUNT=$(git rev-list --count "origin/$BASE_BRANCH..HEAD")
```

Log:

```
Branch has {COMMIT_COUNT} commits ahead of origin/{BASE_BRANCH}
```

**If `--dry-run`:** Print the analysis (base branch, commit count, Drizzle dirs found, migrations that would be removed) and stop here.

---

## Phase 3 -- Execute Rebase

Run the rebase with automatic conflict resolution strategy.

```bash
git rebase "origin/$BASE_BRANCH" --no-autosquash
```

### If rebase completes cleanly

Proceed to Phase 4.

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

for i in $(seq 1 $MAX); do
  # Check if rebase is still in progress
  if [ ! -d .git/rebase-merge ] && [ ! -d .git/rebase-apply ]; then
    echo "REBASE_COMPLETE"
    echo "AUTO_RESOLVED=$AUTO_RESOLVED"
    echo "USER_RESOLVED=$USER_RESOLVED"
    echo "REGENERATE_LOCKFILE=$REGENERATE_LOCKFILE"
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
        git rm "$f" 2>/dev/null || true
      elif [ "$ctype" = "UD" ]; then
        # File modified on base, deleted by feature -- keep base version
        git checkout --ours "$f" 2>/dev/null && git add "$f" 2>/dev/null || true
      else
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

**If the batch loop completes** (`REBASE_COMPLETE`), proceed to Phase 4.

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

## Phase 7 -- Push

**Skip if `--no-push`.**

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
commits-rebased: {N}
conflicts-resolved: {N auto-resolved} auto, {N user-resolved} manual
drizzle-migrations-removed: {N}
drizzle-dirs: {dir1, dir2, ... | none}
lockfile-regenerated: {yes | no}
stash: {restored | not needed}
pushed: {yes | skipped (--no-push) | skipped (--dry-run)}
--- END REBASE RESULT ---
```

---

## Error Handling

| Condition | Action |
|---|---|
| On default branch | Stop with message |
| Base branch not found | Stop: "Branch `{BASE_BRANCH}` not found on origin." |
| `git` not available | Stop with message |
| Rebase unrecoverable | Abort rebase, restore stash, stop with message |
| Push fails | Stop with error, do not lose local state |
| Stash pop conflicts | Warn user, leave stash intact |
| No Drizzle dirs found | Skip migration cleanup silently |
| `gh` not available | Warn (cannot detect PR base), fall back to default branch |
| Lock file regeneration fails | Warn but continue |
