---
name: pst:push
description: Auto-commit, push to PR, refresh PR description, validate test plan, and check off passing items.
argument-hint: "[--dry-run] [--comment] [--no-desc] [--skip-slop]"
allowed-tools: Bash, Read, Grep, Glob, Agent, Skill, AskUserQuestion
---

# Push & Validate

Auto-commit uncommitted changes, push the current branch, ensure a PR exists against the default branch, refresh the PR title and description to reflect all changes on the branch, then validate every unchecked test-plan checkbox locally and check off passing items on the PR.

By default, validation results are shown in the terminal only. Pass `--comment` to also post a validation results comment on the GitHub PR.

This is a lightweight alternative to `/pst:qa` -- terminal commands only, no browser automation.

---

## Input

<arguments> #$ARGUMENTS </arguments>

**Parse arguments:**

- `--dry-run` - analyze and validate locally without pushing, creating PRs, posting comments, or updating checkboxes
- `--comment` - also post a validation results comment on the GitHub PR (Phase 6a)
- `--no-desc` - skip refreshing the PR title and description (Phase 3). Useful when you've manually crafted the PR description and don't want it overwritten.
- `--skip-slop` - bypass the Phase 1.5 slop gate. Use only when you've consciously decided that committed slop is fine (e.g., re-pushing a reviewed branch without re-scanning).
- No arguments - full push, PR refresh, validate, and checkbox update cycle (terminal output only, no GitHub comment)

---

## Phase 1 - Guards & Auto-Commit

Collect state and bail early if preconditions are not met.

```bash
BRANCH=$(git branch --show-current 2>/dev/null)
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
STATUS=$(git status --porcelain 2>/dev/null)
```

| Condition                            | Action                                                                |
| ------------------------------------ | --------------------------------------------------------------------- |
| `$BRANCH` is empty                   | Stop: "Not on a branch. Check out a branch first."                    |
| `$BRANCH` equals `$DEFAULT_BRANCH`   | Stop: "You're on {DEFAULT_BRANCH}. Check out a feature branch first." |
| `gh` not available (`command -v gh`) | Stop: "GitHub CLI (gh) is required but not found."                    |

### Auto-Commit

If `$STATUS` is non-empty (uncommitted changes exist), commit them automatically before pushing.

**Step 1 - Analyze changes:**

```bash
git status --porcelain
git diff
git diff --cached
git log --oneline -5
```

Review the staged and unstaged changes along with recent commit messages to understand the commit style and what changed.

**Step 2 - Stage and commit:**

Stage all tracked modified files and any new files that are clearly part of the work (not secrets, env files, or build artifacts). Do NOT stage:

- `.env*` files (except `.env.example`)
- `credentials*`, `*.pem`, `*.key` files
- `node_modules/`, `dist/`, `build/`, `.next/` directories

```bash
git add <specific files>
```

Generate a concise commit message that follows the repository's existing commit style (check recent `git log --oneline`). Use a single sentence that captures the "why."

```bash
git commit -m "<message>

Co-Authored-By: Claude <noreply@anthropic.com>"
```

**Step 3 - Log result:**

```
Auto-committed: {message} ({N} files)
```

**Skip if `--dry-run`:** Still analyze and log what would be committed, but do not actually stage or commit.

---

## Phase 1.5 - Slop Gate

Defense against AI-generated slop reaching the remote. Runs on every invocation unless `--skip-slop` is set.

**Skip if:** `--skip-slop` OR `--dry-run`.

### 1.5a. Scan

Invoke the slop skill in dry-run mode, scoped to branch changes:

```
Skill("pst:slop", "--dry-run")
```

The skill compares the branch diff against the default branch and reports findings grouped by category and severity (`auto-fix`, `review`, `flag`). See `pst:slop` Phase 2 for the full category list -- em dashes, excessive documentation, disabled quality gates, band-aid exclusions, over-complicated abstractions, dead code, error theater, type safety escapes.

### 1.5b. Triage

Parse the slop scan output. Classify the findings:

| Class             | Severities               | Default Action                     |
| ----------------- | ------------------------ | ---------------------------------- |
| **Clean**         | zero findings            | Continue to Phase 2                |
| **Safe-fix only** | only `auto-fix` findings | Auto-apply fixes, commit, continue |
| **Needs review**  | any `review` findings    | Halt, present findings, ask user   |
| **Blocker**       | any `flag` findings      | Halt, present findings, ask user   |

### 1.5c. Safe-fix only path

If every finding is severity `auto-fix` (em dashes, dead `console.log`, commented-out code, clearly-unnecessary suppression comments):

```
Skill("pst:slop", "--auto")
```

After fixes apply, commit them automatically:

```bash
git add -A
git commit -m "chore: strip AI slop before push

Applied /pst:slop --auto: {brief summary of categories touched}.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

Log: `Slop gate: {N} auto-fixes applied and committed. Continuing.`

Continue to Phase 2.

### 1.5d. Needs-review / blocker path

If any finding has severity `review` or `flag`, **do not push**. Present the full slop report in the terminal, then use **AskUserQuestion**:

> Slop scan flagged {N} items needing a human call:
>
> - **Auto-fix ({N}):** {categories with counts}
> - **Review ({N}):** {categories with counts}
> - **Flag ({N}):** {categories with counts}
>
> Representative findings:
>
> - `{file}:{line}` - {category}: {one-line description}
> - `{file}:{line}` - {category}: {one-line description}
> - ... (up to 5)
>
> Push is blocked until you decide. What should I do?
>
> 1. Apply auto-fix + review fixes, commit, push
> 2. Apply auto-fix only, push anyway (review items stay as-is)
> 3. Walk me through each category before deciding
> 4. Push anyway, I've already reviewed the findings (adds `--skip-slop` ack)
> 5. Abort push

Handle the response:

- **Option 1:** Run `Skill("pst:slop", "--auto")`, commit the fixes with the message in 1.5c, then continue to Phase 2.
- **Option 2:** Invoke `Skill("pst:slop")` interactively and choose its option 2 ("Fix auto-fix items only, show me review items"). Commit if anything changed, then continue to Phase 2. Log the remaining review items for the terminal report. (`pst:slop --auto` would also apply review items, so it cannot be used here.)
- **Option 3:** Invoke `Skill("pst:slop")` (interactive mode, no `--auto`) and let the user pick category-by-category. After it returns, commit any fixes and continue to Phase 2.
- **Option 4:** Log the acknowledgement (`Slop gate bypassed by user: {N} review, {N} flag items acknowledged`) and continue to Phase 2. Include the unresolved findings in the final Output Contract.
- **Option 5:** Stop with exit message `Push aborted at slop gate.` Do not push, do not create/update a PR.

### 1.5e. Scoping and performance

- The slop scan operates on the branch diff only (default mode in `pst:slop`), so it's bounded by the size of the PR, not the repo.
- If `git merge-base` fails or the branch has zero changes vs. the default branch, skip the gate with a note: `Slop gate: no branch changes to scan, skipping.`
- If the slop skill itself errors out, treat it as a soft failure: log the error, warn the user, and continue (so a broken slop scanner doesn't permanently wedge pushes). Do NOT auto-bypass if `--skip-slop` was not set -- ask via AskUserQuestion whether to push anyway.

### 1.5f. Why this gate exists

Concrete trigger case: AI-generated boilerplate (header comment blocks, narration comments, unrequested README sections) shipping in small config files where the human-authored content is a single line. The slop scan's category 2 (Excessive Documentation) catches this. Without the gate, a push routes that material to the remote before anyone sees it. With the gate, the review-severity finding stops the push and surfaces the specific file/lines for a decision.

---

## Phase 2 - Push & PR

### 2a. Push

**Skip if `--dry-run`.**

```bash
git push --force-with-lease origin "$BRANCH"
```

If push fails, stop with the error output. Suggest `git pull --rebase` if it looks like a fast-forward rejection.

### 2b. Find or Create PR

**Check for existing PR:**

```bash
PR_JSON=$(gh pr view --json number,url,body,title,state 2>/dev/null)
```

**If PR exists:** Extract `PR_NUMBER`, `PR_URL`, `PR_BODY`. Log: "PR #{N} found."

If state is `MERGED` or `CLOSED`, stop: "PR #{N} is {state}. Nothing to validate."

**If no PR exists and NOT `--dry-run`:**

Gather context:

```bash
MERGE_BASE=$(git merge-base "origin/$DEFAULT_BRANCH" HEAD)
COMMIT_LOG=$(git log --oneline "$MERGE_BASE..HEAD")
DIFF_STAT=$(git diff --stat "$MERGE_BASE...HEAD")
```

Derive a PR title from the branch name or first commit subject. Build a PR body with:

```markdown
## Summary

{1-3 bullet points from commit messages}

## Test plan

{Generate checkboxes based on what changed:}

- [ ] Build passes
- [ ] Tests pass
- [ ] Lint clean
- [ ] Types check
      {Add more specific items based on the diff - e.g., if new exports were added, check they exist}
```

Create the PR:

```bash
gh pr create --draft --base "$DEFAULT_BRANCH" --head "$BRANCH" --title "$TITLE" --body "$BODY"
```

Store the new `PR_NUMBER`, `PR_URL`, `PR_BODY`.

**If no PR exists and `--dry-run`:** Log "No PR found. Would create one." and stop with a clean output contract (no checkboxes to parse).

---

## Phase 3 - Refresh PR Title & Description

Every run, update the PR title and body to accurately reflect the **full** set of changes on the branch -- not just the latest commit. PRs drift as work accumulates; this phase keeps them honest.

**Skip if `--dry-run`, `--no-desc`, or no PR exists.**

### 3a. Gather Full Branch Context

```bash
MERGE_BASE=$(git merge-base "origin/$DEFAULT_BRANCH" HEAD)
COMMIT_LOG=$(git log --oneline "$MERGE_BASE..HEAD")
COMMIT_COUNT=$(echo "$COMMIT_LOG" | wc -l | tr -d ' ')
DIFF_STAT=$(git diff --stat "$MERGE_BASE...HEAD")
CHANGED_FILES=$(git diff --name-only "$MERGE_BASE...HEAD")
```

Also read the current PR title and body:

```bash
CURRENT_TITLE=$(gh pr view $PR_NUMBER --json title --jq .title)
CURRENT_BODY=$(gh pr view $PR_NUMBER --json body --jq .body)
```

### 3b. Decide Whether to Update

Compare the current PR content against the full branch diff. An update is needed if any of these are true:

- The title no longer reflects the scope of work (e.g., title says "Add X" but the branch also modifies Y and Z)
- The Summary section is missing, incomplete, or describes a subset of the commits
- The Test plan section is missing or has no checkboxes
- New commits introduced changes not mentioned anywhere in the body

If the PR was just created in Phase 2, skip this phase (it is already up to date).

### 3c. Generate Updated Content

**Title:** Derive from the full commit log. Keep it under 70 characters. If the branch has a single focus, use that. If multiple distinct changes exist, use a summary title (e.g., "Add /pst:push skill with auto-commit and PR refresh").

**Body:** Preserve the existing structure but refresh the content. The body has two critical sections:

**Summary section** -- rewrite from scratch based on the full commit log and diff:

```markdown
## Summary

- {bullet point per logical change, derived from commits and diff}
- {cover ALL changes on the branch, not just the latest commit}
```

**Test plan section** -- merge existing checkboxes with any new ones needed:

1. Keep all existing checkboxes and their checked/unchecked state
2. Add new checkboxes for changes not covered by existing items
3. Remove checkboxes that reference code/features no longer in the diff
4. Standard checkboxes (build, test, lint, typecheck) should always be present if the project has those scripts

```markdown
## Test plan

- [x] {previously checked items stay checked}
- [ ] {existing unchecked items preserved}
- [ ] {new items for newly introduced changes}
```

**Other sections** -- preserve any other content in the body verbatim (e.g., screenshots, links, reviewer notes). Do not remove content you did not generate.

### 3d. Apply Update

```bash
gh api repos/{owner}/{repo}/pulls/$PR_NUMBER --method PATCH \
  --field title="$NEW_TITLE" \
  --field body="$NEW_BODY"
```

**Log result:**

```
PR updated: title and description refreshed ({COMMIT_COUNT} commits, {N} files changed)
```

Store the updated body as `PR_BODY` for checkbox parsing in the next phase.

---

## Phase 4 - Parse Checkboxes

Parse all unchecked checkboxes (`- [ ] ...`) from `PR_BODY`. Store them in a tracking list:

```
PR_CHECKBOXES = [
  { index: 0, text: "Build passes", checked: false },
  { index: 1, text: "Tests pass", checked: false },
  ...
]
```

The `index` is the positional occurrence of the checkbox in the full PR body (0-based). This is used later to update the correct checkbox.

**If no unchecked checkboxes found:** Print "No unchecked test plan items found in PR #{N}. Nothing to validate." and skip to the Output Contract with all zeros.

---

## Phase 5 - Validate

For each unchecked checkbox, interpret the text and run a code-level validation.

### Package Manager Detection

```bash
if [ -f pnpm-lock.yaml ]; then PKG="pnpm"
elif [ -f yarn.lock ]; then PKG="yarn"
else PKG="npm"; fi
```

### Validation Mapping

Interpret each checkbox's text and map it to a validation command. Use case-insensitive matching on the checkbox text.

| Checkbox text matches                            | Validation                                                                          |
| ------------------------------------------------ | ----------------------------------------------------------------------------------- |
| `build` or `compile`                             | `$PKG run build`                                                                    |
| `test` (but not `typecheck`)                     | `$PKG run test`                                                                     |
| `lint`                                           | `$PKG run lint`                                                                     |
| `typecheck` or `type check` or `types`           | `$PKG run typecheck`                                                                |
| `coverage`                                       | `$PKG run test:coverage`                                                            |
| `ci pass` or `checks pass`                       | `gh pr checks $PR_NUMBER --json name,state` (pass if all conclusions are "SUCCESS") |
| References a specific file path                  | Use Glob to verify the file exists                                                  |
| References a specific export or function         | Use Grep to verify it exists in the codebase                                        |
| Requires browser, visual, or manual verification | Verdict: `skip` with reason "requires browser/manual verification"                  |
| Cannot determine validation approach             | Verdict: `skip` with reason "unable to determine validation command"                |

### Execution

For each checkbox:

1. Log: `Validating [{index}]: {text}`
2. Determine validation command(s) from the mapping above
3. Execute with a 5-minute timeout
4. Record verdict:
   - `pass` - command exited 0 (or assertion confirmed)
   - `fail` - command exited non-zero (include brief error summary)
   - `skip` - not verifiable via terminal, or command not available in project
5. Store brief reasoning (e.g., "build exited 0", "`pnpm run test` failed with 3 errors", "no typecheck script found")

**Caching:** If multiple checkboxes map to the same underlying command, run it once and reuse the result for all matching checkboxes.

**Missing scripts:** If a checkbox maps to a package.json script that does not exist, verdict is `skip` with reason "no {script} script in package.json".

---

## Phase 6 - Report & Update

### 6a. Post Validation Comment

**Skip unless `--comment`. Skip if `--dry-run`.**

```bash
gh pr comment $PR_NUMBER --body "$(cat <<'EOF'
## Validation Results

| # | Checkbox | Verdict | Notes |
|---|----------|---------|-------|
| 1 | Build passes | PASS | exit 0 |
| 2 | Tests pass | FAIL | 3 failures in auth.test.ts |
| 3 | UI renders correctly | SKIP | requires browser |

**Summary:** {N} passed, {N} failed, {N} skipped

Generated by `/pst:push`
EOF
)"
```

### 6b. Update PR Checkboxes

**Skip if `--dry-run`.**

Check off any PR description checkboxes whose validation passed.

**Step 1 - Identify passed checkboxes:**

From the validation results, collect all checkboxes with verdict `pass`.

**Step 2 - Fetch current PR body:**

```bash
PR_BODY=$(gh pr view $PR_NUMBER --json body --jq .body)
```

**Step 3 - Replace checkboxes:**

For each passed checkbox index, replace the Nth unchecked checkbox (`- [ ]`) with a checked one (`- [x]`). Process replacements from **highest index to lowest** to preserve positional accuracy.

**Step 4 - Update PR description:**

Use the GitHub API to update the PR body (avoids token scope issues with `gh pr edit`):

```bash
gh api repos/{owner}/{repo}/pulls/$PR_NUMBER --method PATCH --field body="$UPDATED_BODY"
```

**Step 5 - Log result:**

```
PR checkboxes updated: {N} of {total} checked off
```

Leave `fail` and `skip` checkboxes unchecked.

### 6c. Terminal Output

Always print the results table to the terminal, regardless of mode.

### Output Contract

Always print this block at the end for machine parsing:

```
--- PUSH RESULT ---
branch: {BRANCH}
pr: #{N} ({url})
slop-gate: {clean|fixed N|acknowledged N review + N flag|skipped (--skip-slop)|skipped (dry-run)|error: {reason}}
pushed: {yes|skipped (dry-run)|aborted at slop gate}
pr-refreshed: {yes|no (just created)|skipped (dry-run)|skipped (--no-desc)}
checkboxes: {total found}
pass: {N} | fail: {N} | skip: {N}
pr-comment: {posted|skipped (dry-run)|skipped (no --comment)}
pr-checkboxes: {N checked}/{total}
--- END PUSH RESULT ---
```

---

## Error Handling

| Condition                              | Action                                         |
| -------------------------------------- | ---------------------------------------------- |
| On default branch                      | Stop with message                              |
| Dirty working tree                     | Auto-commit (skip secrets/env/build artifacts) |
| `gh` not installed/authed              | Stop with message                              |
| Push fails                             | Stop with error, suggest `git pull --rebase`   |
| PR creation fails                      | Stop with error, print gh output               |
| No checkboxes found                    | Print message, stop with clean output contract |
| Validation command times out (5 min)   | Verdict: `skip`, reason: "timed out"           |
| Validation command not in package.json | Verdict: `skip`, reason: "no {script} script"  |
| PR body update fails (422 or other)    | Warn but do not fail the whole run             |
