---
name: pst:next
description: Assess current workflow state and recommend the single best next step
argument-hint: "[--verbose | --why]"
allowed-tools: Bash, Read, Grep, Glob
---

# What's Next?

Assess the current state of the working directory - git, GitHub, project files - and recommend the single best next action. Opinionated. One answer, not a menu.

---

## Input

<arguments> #$ARGUMENTS </arguments>

**Parse arguments:**

- `--verbose` - print full state assessment before the recommendation
- `--why` - include one-line reasoning after the recommendation
- No arguments - just the recommendation

---

## Phase 1 - State Gathering

Collect all signals before making a decision. Run the git and GitHub commands in parallel where possible.

### 1a. Git State

```bash
# Current branch
BRANCH=$(git branch --show-current 2>/dev/null)

# Default branch
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

# Working tree status
STATUS=$(git status --porcelain 2>/dev/null)

# Rebase or merge in progress
GIT_DIR=$(git rev-parse --git-dir 2>/dev/null)
REBASE_IN_PROGRESS=false
if [[ -d "$GIT_DIR/rebase-merge" ]] || [[ -d "$GIT_DIR/rebase-apply" ]]; then
  REBASE_IN_PROGRESS=true
fi
MERGE_IN_PROGRESS=false
if [[ -f "$GIT_DIR/MERGE_HEAD" ]]; then
  MERGE_IN_PROGRESS=true
fi

# Commits ahead of default branch (only on feature branches)
if [[ "$BRANCH" != "$DEFAULT_BRANCH" ]]; then
  COMMITS_AHEAD=$(git log --oneline "$DEFAULT_BRANCH..HEAD" 2>/dev/null | wc -l | tr -d ' ')
  CHANGED_FILES=$(git diff --name-only "$DEFAULT_BRANCH...HEAD" 2>/dev/null)
fi
```

If `git branch --show-current` fails or returns empty, this is not a git repo or HEAD is detached. Handle in the decision tree.

### 1b. GitHub State

Skip this section entirely if `gh` is not installed (`command -v gh`). If it is installed, attempt to fetch PR info for the current branch. Failures are non-fatal - just means no PR exists or `gh` is not authenticated.

```bash
PR_JSON=$(gh pr view --json number,state,title,reviewDecision,statusCheckRollup,url 2>/dev/null)
```

If `PR_JSON` is non-empty, extract:

- `PR_NUMBER` - the PR number
- `PR_STATE` - OPEN, CLOSED, or MERGED
- `REVIEW_DECISION` - APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or empty
- `CI_STATUS` - derive from `statusCheckRollup`: all SUCCESS = "passing", any FAILURE = "failing", any PENDING = "pending", empty = "unknown"

### 1c. Project Context

Use Glob and Read to detect project characteristics:

- **Has quality scripts:** Read `package.json` (if it exists) and check for `build`, `lint`, `typecheck`, `test` in the `scripts` object. Store as `HAS_QUALITY_SCRIPTS=true/false`.
- **Changed file categories:** From `CHANGED_FILES`, categorize:
  - TSX files: count of `*.tsx` files
  - Test files: count of `*.test.*` or `*.spec.*` files
  - Total files changed
- **Figma references:** Grep recent commit messages (`git log --oneline -20`) and PR body (if available) for `figma.com`. Store as `HAS_FIGMA_REF=true/false`.

---

## Phase 2 - Decision

Evaluate the following rules **top-to-bottom**. First match wins. Output the recommendation and stop.

---

### Rule 1: Not a git repo

**Condition:** `git branch --show-current` failed or `$GIT_DIR` does not exist.

**Output:**

```
Not a git repo. Nothing to assess.
```

Stop.

---

### Rule 2: Detached HEAD

**Condition:** `$BRANCH` is empty (detached HEAD state).

**Output:**

```
NEXT STEP
---------
You're in detached HEAD state. Check out a branch before continuing.

  git checkout <branch-name>
```

---

### Rule 3: Rebase in progress

**Condition:** `$REBASE_IN_PROGRESS` is true.

**Output:**

```
NEXT STEP
---------
A rebase is in progress. Finish it before doing anything else.

  git rebase --continue
```

**Why:** Rebase blocks all other git operations. Must be resolved first.

---

### Rule 4: Merge conflict

**Condition:** `$MERGE_IN_PROGRESS` is true, or `$STATUS` contains lines starting with `U` (unmerged).

**Output:**

```
NEXT STEP
---------
You have unresolved merge conflicts. Resolve them and complete the merge.

  git status
```

**Why:** Merge conflicts block all forward progress. Fix them first.

---

### Rule 5: Dirty working tree

**Condition:** `$STATUS` is non-empty (uncommitted changes exist).

Inspect the status to give a more specific recommendation:

- If only untracked files: mention them specifically
- If staged + unstaged: recommend committing what's staged
- General case: recommend committing

**Output:**

```
NEXT STEP
---------
You have uncommitted changes ({N} files). Commit or stash before moving forward.

  git add -p && git commit
```

**Why:** Most skills assume a reasonably clean working tree. Uncommitted work should be captured before switching context.

---

### Rule 6: On default branch, clean tree

**Condition:** `$BRANCH` equals `$DEFAULT_BRANCH` and `$STATUS` is empty.

**Output:**

```
NEXT STEP
---------
You're on {DEFAULT_BRANCH} with a clean tree. Time to start something new.

  /spec-gen

If you already know what to build, create a branch: git checkout -b feature/<name>
```

**Why:** `/spec-gen` is the best starting point when requirements need definition. If the user already knows what to build, the branch creation hint gets them moving.

---

### Rule 7: Feature branch, PR merged

**Condition:** `$PR_STATE` is `MERGED`.

**Output:**

```
NEXT STEP
---------
PR #{PR_NUMBER} is merged. Clean up and get back to {DEFAULT_BRANCH}.

  git checkout {DEFAULT_BRANCH} && git pull && git branch -d {BRANCH}
```

**Why:** Stale feature branches create clutter. Clean up promptly.

---

### Rule 8: Feature branch, PR closed (not merged)

**Condition:** `$PR_STATE` is `CLOSED`.

**Output:**

```
NEXT STEP
---------
PR #{PR_NUMBER} was closed without merging. Decide whether to reopen or abandon this branch.

  gh pr view {PR_NUMBER} --web
```

**Why:** Closed PRs need a human decision - reopen, rework, or abandon.

---

### Rule 9: Feature branch, PR exists, changes requested

**Condition:** `$PR_STATE` is `OPEN` and `$REVIEW_DECISION` is `CHANGES_REQUESTED`.

**Output:**

```
NEXT STEP
---------
Changes requested on PR #{PR_NUMBER}. Address the review feedback, then validate.

  gh pr view {PR_NUMBER} --web

After addressing feedback:
  /validate-quality-gates
```

**Why:** Review feedback is the highest-priority open item when someone is waiting on you.

---

### Rule 10: Feature branch, PR exists, CI failing

**Condition:** `$PR_STATE` is `OPEN` and `$CI_STATUS` is `failing`.

**Output:**

```
NEXT STEP
---------
CI is failing on PR #{PR_NUMBER}. Fix the quality gates.

  /validate-quality-gates
```

**Why:** Nothing moves forward with red CI. Fix it before requesting review or running QA.

---

### Rule 11: Feature branch, PR exists, CI passing, no review

**Condition:** `$PR_STATE` is `OPEN`, `$CI_STATUS` is `passing` or `unknown`, and `$REVIEW_DECISION` is empty or `REVIEW_REQUIRED`.

**Output:**

```
NEXT STEP
---------
PR #{PR_NUMBER} is up and CI is green. Get it reviewed.

  /pst:code-review {PR_NUMBER}
```

**Why:** Code review is the gate between "code works" and "code is ready." `/pst:code-review` validates findings in isolated worktrees so every reported issue has a proven fix.

---

### Rule 12: Feature branch, PR exists, approved, CI passing

**Condition:** `$PR_STATE` is `OPEN`, `$REVIEW_DECISION` is `APPROVED`, and `$CI_STATUS` is `passing` or `unknown`.

**Output:**

```
NEXT STEP
---------
PR #{PR_NUMBER} is approved and CI is green. Run final QA, then merge.

  /pst:qa {PR_NUMBER}
```

**Why:** QA is the last gate before merge. `/pst:qa` synthesizes a test plan from the PR context and executes it via browser automation.

---

### Rule 13: Feature branch, commits ahead, no PR, heavy .tsx changes

**Condition:** No PR exists, `$COMMITS_AHEAD` > 0, and the changed files contain 5+ `.tsx` files with fewer than 2 test file changes.

**Output:**

```
NEXT STEP
---------
You've changed {N} React components with minimal test coverage. Extract business logic before opening a PR.

  /pst:react-refactor
```

**Why:** Components with inline business logic are harder to review and test. Extracting to hooks first makes the PR cleaner and more reviewable.

---

### Rule 14: Feature branch, commits ahead, no PR, has quality scripts

**Condition:** No PR exists, `$COMMITS_AHEAD` > 0, and `$HAS_QUALITY_SCRIPTS` is true.

**Output:**

```
NEXT STEP
---------
You have {COMMITS_AHEAD} commits on {BRANCH} with no PR. Run quality gates before opening one.

  /validate-quality-gates

Then sweep for AI slop before the PR goes up:
  /pst:slop
```

**Why:** Catching build/lint/type/test failures before opening a PR saves review cycles and keeps CI green from the start. A slop sweep after quality gates catches the cosmetic and structural issues that linters miss - em dashes, excessive docs, dead code, unnecessary abstractions.

---

### Rule 14b: Feature branch, PR exists, CI passing, pre-review slop check

**Condition:** `$PR_STATE` is `OPEN`, `$CI_STATUS` is `passing`, `$REVIEW_DECISION` is empty or `REVIEW_REQUIRED`, and the branch diff contains potential slop signals.

To detect slop signals cheaply (without running the full skill), check:

```bash
# Quick slop sniff - any of these in the branch diff?
DIFF_CONTENT=$(git diff "$DEFAULT_BRANCH...HEAD")
SLOP_SIGNALS=0
echo "$DIFF_CONTENT" | grep -cP '\x{2014}' && SLOP_SIGNALS=$((SLOP_SIGNALS + 1))  # em dash
echo "$DIFF_CONTENT" | grep -c 'eslint-disable' && SLOP_SIGNALS=$((SLOP_SIGNALS + 1))
echo "$DIFF_CONTENT" | grep -c '@ts-ignore\|@ts-nocheck' && SLOP_SIGNALS=$((SLOP_SIGNALS + 1))
echo "$DIFF_CONTENT" | grep -c 'console\.log' && SLOP_SIGNALS=$((SLOP_SIGNALS + 1))
echo "$DIFF_CONTENT" | grep -c 'as any' && SLOP_SIGNALS=$((SLOP_SIGNALS + 1))
echo "$DIFF_CONTENT" | grep -c '\.skip(' && SLOP_SIGNALS=$((SLOP_SIGNALS + 1))
```

If `SLOP_SIGNALS` > 0, this rule matches **instead of** Rule 11 (code review). Clean up slop before requesting review.

**Output:**

```
NEXT STEP
---------
PR #{PR_NUMBER} is up and CI is green, but I spotted slop signals in the diff. Clean up before review.

  /pst:slop

Then get it reviewed:
  /pst:code-review {PR_NUMBER}
```

**Why:** Reviewers should spend time on logic and architecture, not pointing out em dashes, `console.log` leftovers, or `eslint-disable` comments. A quick slop sweep respects their time.

---

### Rule 15: Feature branch, commits ahead, no PR, no quality scripts

**Condition:** No PR exists and `$COMMITS_AHEAD` > 0.

**Output:**

```
NEXT STEP
---------
You have {COMMITS_AHEAD} commits on {BRANCH}. Time to open a PR.

  gh pr create
```

---

### Rule 16: Feature branch, fresh (0 commits ahead)

**Condition:** On a feature branch with 0 commits ahead of the default branch.

Check for Figma references in the branch name or recent context:

- If `$HAS_FIGMA_REF` is true or the branch name contains `figma`, `design`, or `ui`:

```
NEXT STEP
---------
Fresh branch. If you have a Figma design to implement:

  /pst:figma <figma-url>

Otherwise, start writing code.
```

- Otherwise:

```
NEXT STEP
---------
Fresh branch {BRANCH}. Start implementing.

If requirements are unclear: /spec-gen
```

---

### Rule 17: Fallback

If no rule matched (should be rare):

**Output:**

```
NEXT STEP
---------
I can see the state but I'm not sure what's best here. Let's decide together.

  /decide-for-me
```

Print a brief state summary regardless of `--verbose` flag, so the user has context.

---

## Phase 3 - Output

### Standard Mode (no flags)

Print only the `NEXT STEP` block from the matched rule.

### Verbose Mode (`--verbose`)

Before the `NEXT STEP` block, print a state assessment:

```
STATE
-----
Branch:          {BRANCH}
Default branch:  {DEFAULT_BRANCH}
Working tree:    {clean | N uncommitted files}
Commits ahead:   {N}
PR:              {#N (STATE) | none}
CI:              {passing | failing | pending | unknown | N/A}
Review:          {APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED | none | N/A}
Changed files:   {N total} ({tsx}: {M}, tests: {K}, other: {J})
Quality scripts: {yes | no | no package.json}
Figma refs:      {yes | no}
```

Then print the `NEXT STEP` block.

### Why Mode (`--why`)

Print the `NEXT STEP` block, then append the **Why:** line from the matched rule.

---

## Error Handling

| Condition | Action |
|-----------|--------|
| Not a git repo | Exit with message (Rule 1) |
| `gh` not installed or not authenticated | Skip GitHub signals; decision tree still works on git-only rules; append note: "(GitHub state unavailable - install/auth `gh` for better recommendations)" |
| Detached HEAD | Rule 2 |
| No `package.json` | `HAS_QUALITY_SCRIPTS=false`; skip React-specific recommendations |
| No remote configured | Skip ahead/behind computation; treat as "fresh branch" if on non-default branch |
| Default branch detection fails | Fall back to `main` |
