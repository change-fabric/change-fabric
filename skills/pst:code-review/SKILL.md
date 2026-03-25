---
name: pst:code-review
description: Code review with worktree-isolated fix verification - every finding must survive a quality gate before being reported
argument-hint: "[PR-number | PR-URL | --local | --preflight | --autofix | --sweep]"
allowed-tools: Bash, Read, Edit, Grep, Glob, Agent, AskUserQuestion
---

# Code Review with Fix Verification

Perform a **context-aware code review** where every finding is validated by applying the suggested fix in an isolated worktree and running quality gates. Findings that break the build, fail tests, or can't be cleanly applied are dropped before reporting. This eliminates false positives and ensures every reported issue has a proven fix.

---

## Input Parsing

<arguments> #$ARGUMENTS </arguments>

**Parse arguments:**

- PR number (e.g., `42`)
- PR URL (e.g., `https://github.com/{owner}/{repo}/pull/{N}`) - including cross-repo
- `--local` - terminal output only, no GitHub interaction
- `--preflight` - alias for `--local`. Terminal output only, no GitHub interaction
- `--autofix` - fully autonomous: apply all verified fixes + auto-approve the PR
- `--sweep` - multi-round autonomous review-and-fix loop until clean or max rounds

**Default: GitHub PR mode** (post review to PR). `--local` or `--preflight` for terminal-only output. `--autofix` for autonomous fix + approve. `--sweep` for iterative cleanup.

**Cross-repo detection:** If URL points to a different repo than the current directory:

```bash
TMPDIR="${TMPDIR:-${TEMP:-/tmp}}"
REVIEW_DIR=$(mktemp -d "$TMPDIR/pst-review-XXXXXX")
gh repo clone {owner}/{repo} "$REVIEW_DIR" -- --depth=50
cd "$REVIEW_DIR" && gh pr checkout {N}
```

**Re-review detection:** Check for an existing review from a prior run via `gh api /repos/{owner}/{repo}/pulls/{N}/reviews`. If a previous review exists, scope the diff to changes since the last reviewed commit. Only report critical and warning findings (no nits on re-review). If 0 criticals + 0 warnings → post APPROVE.

---

## Workspace Setup

Combines worktree isolation and branch freshness checking into a single stage.

**Skip if `--sweep`** - sweep mode operates on the current working directory against the default branch.

**Skip if cross-repo** - already cloned to `REVIEW_DIR` above.

**Resolve PR head:**

```bash
HEAD_BRANCH=$(gh pr view $N --json headRefName --jq .headRefName)
HEAD_SHA=$(gh pr view $N --json headRefOid --jq .headRefOid)
```

**Skip worktree if all true:**

1. Current branch matches `$HEAD_BRANCH`
2. `HEAD` matches `$HEAD_SHA`
3. Working tree is clean (`git status --porcelain` empty)

**Otherwise, create a detached worktree:**

```bash
REPO_ROOT=$(git rev-parse --path-format=absolute --git-common-dir | sed 's|/.git$||')
git fetch origin "$HEAD_BRANCH"
REVIEW_DIR="$REPO_ROOT/.worktrees/review-PR-$N"
git worktree remove --force "$REVIEW_DIR" 2>/dev/null
git worktree add --detach "$REVIEW_DIR" "$HEAD_SHA"
```

Set `REVIEW_WORKTREE=true`, work from `$REVIEW_DIR` for all subsequent stages.

**Branch freshness check:**

```bash
BASE_BRANCH=$(gh pr view $N --json baseRefName --jq .baseRefName)
git fetch origin "$BASE_BRANCH"
git merge-base --is-ancestor "origin/$BASE_BRANCH" HEAD
```

- **Current (exit 0):** Proceed.
- **Stale (exit 1):** Check for migration files in the diff (`migrations/`, `drizzle/`, `prisma/migrations/`).
  - Migrations present → **critical** finding: "Branch is behind `$BASE_BRANCH` and contains migrations. Rebase required to prevent migration ordering issues."
  - No migrations → **warning** finding: "Branch is behind `$BASE_BRANCH`. Consider rebasing for clean history."

In `--autofix` mode: report staleness but do NOT auto-rebase (that's a developer decision).

For `--sweep` mode: compute merge-base via `git merge-base origin/$DEFAULT_BRANCH HEAD` where `$DEFAULT_BRANCH` is read from the repo's GitHub default branch.

---

## Context Gathering

Build a picture of the codebase and the change under review. No external project management tool integration - all context comes from the repo and PR.

1. **Repo context**: Read `CLAUDE.md`, `.context/architecture.md`, `.context/patterns.md`, recent ADRs (cap at 10 most recent)
2. **PR metadata**: `gh pr view {N} --json number,title,body,baseRefName,headRefName,url,labels` + `gh pr diff {N}`
   - For `--sweep` mode: skip `gh pr view`. Use `git diff $(git merge-base origin/$DEFAULT_BRANCH HEAD)...HEAD`. No AskUserQuestion calls (fully autonomous).
   - **PR Checkbox Tracking:** Parse all unchecked checkboxes (`- [ ] ...`) from the PR body. Store them for later:
     ```
     PR_CHECKBOXES = [
       { index: 0, text: "Verify no regressions in auth flow", checked: false },
       { index: 1, text: "Confirm error handling for edge case X", checked: false },
       ...
     ]
     ```
     The `index` is the positional occurrence (0-based) in the full PR body. Include checkbox items as additional review verification targets - if a checkbox describes something verifiable through code analysis (e.g., "no regressions", "handles edge case X"), treat it as a review item to validate during Analysis.
3. **Commit messages**: `git log --oneline {base}...HEAD` - understand the narrative of changes
4. **No context available?** → Use AskUserQuestion: "What is this project? Key architectural patterns? Critical invariants?" - gather minimum sufficient context for this review round.
5. **Pattern inference**: For each changed file, sample 2-3 similar files (same directory, same extension). Detect patterns: naming conventions, import ordering, error handling style, test structure. Only flag deviations when **75%+ of sampled files agree** on a pattern. Tag these as "inferred pattern" findings.

---

## Analysis

Generate candidate review findings from the diff.

1. **Get the diff**: `gh pr diff {N}` or `git diff $MERGE_BASE...HEAD`
2. **Large diff triage**: 100+ changed files → prioritize by risk (security-sensitive > core logic > UI/config), cap analysis at 50 files, note what was skipped
3. **Analyze through categories in priority order:**
   - Security (injection, auth, secrets, input validation)
   - Reliability (error handling, null safety, race conditions, resource leaks)
   - Correctness (logic errors, off-by-one, wrong assumptions)
   - Maintainability (complexity, coupling, naming, dead code)
   - Performance (N+1 queries, unnecessary re-renders, missing indexes)
4. **Generate candidate findings** with format:
   - ID: `R{N}` (sequential)
   - Severity: `critical` | `warning` | `nit`
   - File + line range
   - Category (from list above)
   - Title (short)
   - Problem description (1-2 sentences)
   - Suggested fix (specific, minimal)
5. **Pre-filter**: Drop findings that are:
   - Style nitpicks mis-classified as warnings → downgrade to nit or drop
   - Already caught by CI tooling (eslint, tsc, prettier) → drop
   - Missing a concrete, actionable fix → drop

---

## Verification

The core differentiator: every candidate finding is validated by a sub-agent that applies the fix and runs quality gates.

**For EACH candidate finding**, spawn a sub-agent:

```
Agent:
  description: "Verify finding R{N}: {title}"
  isolation: worktree
  run_in_background: true
```

**All agents spawn simultaneously.** Each gets its own isolated worktree copy of the code.

**Sub-agent workflow:**

1. Read the file and surrounding code context
2. **Trace the dependency graph** - follow callers/callees until hitting system boundaries (API, DB, external service). Understand the blast radius.
3. Validate against: ADRs, patterns files, inferred patterns from the Analysis stage
4. **Filter check** - DISCARD the finding if:
   - It's a style preference disguised as a warning (rename, blank line, import order)
   - It flags a phantom bug from incomplete context (e.g., non-null flagged as nullable when the type system guarantees it)
   - CI tooling would already catch it (eslint, tsc, prettier rules)
   - It's over-engineering (excessive abstraction, unnecessary error handling for impossible cases)
   - The fix would break existing tests or API contracts
   - It doesn't materially affect reliability, correctness, or maintainability
5. **Apply the suggested fix** in the worktree (minimum edit, don't refactor beyond the finding)
6. **Run quality gates**: detect package manager, then execute:
   ```bash
   $PKG_MANAGER run build 2>&1
   $PKG_MANAGER run lint 2>&1
   $PKG_MANAGER run typecheck 2>&1
   $PKG_MANAGER run test 2>&1
   ```
   If any gate fails → **drop the finding entirely**. If the repo has no test suite, treat the test gate as N/A.
7. Produce a verdict: `VERIFIED` (fix works, gates pass) or `DROPPED` (fix breaks something or finding is invalid)

**After all sub-agents complete:**

- Collect results. VERIFIED findings proceed to Reporting. DROPPED findings are discarded silently.
- Clean up all verification worktrees.

---

## Reporting

### GitHub PR Mode (default)

Post a single grouped review via `gh api POST /repos/{owner}/{repo}/pulls/{N}/reviews`:

- Event: `REQUEST_CHANGES` if any critical finding, else `COMMENT`
- Body: Summary (max 8 bullets) + findings table + count of dropped findings

Get `commit_id`: `gh pr view <N> --json headRefOid --jq .headRefOid` (validate `^[0-9a-f]{40}$`; fallback: `git rev-parse HEAD`; both fail → body-only review via `gh pr review`).

Write comments to a temp JSON file, pass via `--input`, clean up after.

**Inline comment format:**

````markdown
**R{N}** `{severity}` - {title}

{problem description in 1-2 sentences}

**Fix:** {specific change needed}

<details>
<summary>Verification Details</summary>

**Blast radius:** {dependency trace summary}
**Context checked:** {ADRs, patterns, inferred conventions referenced}
**Quality gates:** PASSED (build, lint, typecheck, test)

</details>

<details>
<summary>Fix Prompt (paste into any AI tool)</summary>

```
Fix R{N} from a code review.
Repo: {repo} | PR: #{N} | File: {path} | Location: {function/line-range}

Problem: {precise description}
Required change: {smallest possible fix}
Expected outcome: {correct behavior}
Verify: {test command + expected result}
```

</details>

```suggestion
{code suggestion if applicable}
```
````

**Shell safety:** always wrap body in heredoc with single-quoted delimiter (`'EOF'`).

### Local Mode (`--local` / `--preflight`)

Same Analysis + Verification stages. Output findings to terminal with severity markers. No GitHub interaction. No code edits.

### Autofix Mode (`--autofix`)

- Fully autonomous (no AskUserQuestion calls)
- Auto-apply all verified fixes (they've already proven to pass quality gates)
- One squashed commit for all fixes
- If 0 criticals remain + PR exists → auto-post APPROVE via GitHub API

### Sweep Mode (`--sweep`)

Multi-round autonomous code review with auto-fix. No GitHub interaction.

**Constants:** `MIN_ROUNDS = 2`, `MAX_ROUNDS = 5`

**Round loop:**

1. Compute diff: `git diff $(git merge-base origin/$DEFAULT_BRANCH HEAD)...HEAD`
2. Run full Analysis + Verification (autonomous, no AskUserQuestion)
3. Collect VERIFIED findings (criticals + warnings only - skip nits in sweep)
4. If `round >= MIN_ROUNDS` AND 0 criticals → print clean summary, exit loop
5. If criticals found:
   - Auto-apply all verified fixes
   - `git add {fixed files}`
   - `git commit -m "fix: sweep round {N} findings"`
   - Print round summary
6. If `round == MAX_ROUNDS` AND criticals remain → report remaining, exit loop

**Terminal output per round:**

```
SWEEP ROUND {N}/{MAX}
Criticals: {n} | Warnings: {n} | Nits: {n}
Fixed: {file list} | Commit: {short hash}
```

**Final summary:**

```
SWEEP COMPLETE - {N} round(s), {total fixes} applied, status: CLEAN|REMAINING
```

### Conversation Resolution

**Skip if `--sweep` or `--local`.**

After posting the review, check for unresolved conversations from prior reviews:

```bash
gh api repos/{owner}/{repo}/pulls/{N}/comments --jq '[.[] | select(.in_reply_to_id == null)] | length'
```

If unresolved conversations exist, present each via **AskUserQuestion** with options: Reply Fixed (cite commit), Won't Fix (explain), Acknowledged, or Skip.

Post replies for each addressed conversation and resolve threads via GraphQL:

```bash
gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "THREAD_NODE_ID"}) { thread { isResolved } } }'
```

To get thread node IDs, query review threads before prompting:

```bash
gh api graphql -f query='{ repository(owner: "OWNER", name: "REPO") { pullRequest(number: N) { reviewThreads(first: 50) { nodes { id isResolved comments(first: 1) { nodes { databaseId body path line } } } } } } }'
```

Match `databaseId` to REST comment IDs to correlate threads. **Always resolve after replying** - responding without resolving leaves conversations dangling.

In `--autofix` mode: auto-reply "Fixed" for conversations whose findings were addressed in this run. Leave others unresolved.

### Update PR Checkboxes

**Skip if:** `--sweep`, `--local`, `--preflight`, or no PR exists, or no `PR_CHECKBOXES` were found.

After posting the review and resolving conversations, check off PR description checkboxes that were verified through code analysis.

**Which checkboxes to check off:**

A PR checkbox is eligible to be checked if:

- It describes something verifiable through static code analysis (e.g., "handles error case X", "validates input", "no regressions in Y")
- The review confirmed the behavior is correct - either no related findings, or related findings were all nits
- It was NOT contradicted by a critical or warning finding

Do NOT check off checkboxes that:

- Require runtime/manual testing to verify (e.g., "test in staging", "verify UI looks correct")
- Were associated with a critical or warning finding
- Are ambiguous or cannot be determined from code analysis alone

**Step 1 - Fetch current PR body:**

```bash
PR_BODY=$(gh pr view $PR_NUMBER --json body --jq .body)
```

**Step 2 - Replace checkboxes:**

For each verified checkbox index, replace the Nth unchecked checkbox (`- [ ]`) with `- [x]`. Process from highest index to lowest.

**Step 3 - Update PR description:**

```bash
gh api repos/{owner}/{repo}/pulls/$PR_NUMBER --method PATCH --field body="$UPDATED_BODY"
```

**Step 4 - Log result:**

```
PR checkboxes updated: {N} of {total} checked off ({M} require manual/runtime verification)
```

In `--autofix` mode: also check off checkboxes if the autofix resolved a related finding.

### Worktree Cleanup

If `REVIEW_WORKTREE=true`:

```bash
cd "$REPO_ROOT"
git worktree remove --force "$REVIEW_DIR"
```

If removal fails, warn with manual cleanup command.

### Error Handling

| Condition                  | Action                                             |
| -------------------------- | -------------------------------------------------- |
| 401/403 from GitHub        | Instruct `gh auth login`                           |
| 422 (invalid line comment) | Remove invalid comments, retry                     |
| 429 (rate limit)           | Wait, retry, fallback to body-only                 |
| Empty diff                 | Exit with message                                  |
| Sub-agent worktree failure | Skip that finding with "unverified" caveat         |
| All sub-agents fail        | Fall back to unverified review with warning banner |
| Worktree creation fails    | Fall back to reviewing in host repo with warning   |
| Worktree cleanup fails     | Warn with manual cleanup command                   |
| Sweep max rounds exceeded  | Report remaining issues, exit                      |
