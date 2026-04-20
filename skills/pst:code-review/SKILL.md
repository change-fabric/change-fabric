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
- `--local` - terminal output only, no GitHub interaction (single pass)
- `--preflight` - multi-round local review with auto-fix (min 3, max 5 rounds). No GitHub interaction. Applies all verified fixes and commits.
- `--autofix` - fully autonomous: apply all verified fixes + auto-approve the PR
- `--sweep` - multi-round autonomous review-and-fix loop until clean or max rounds

**Default: GitHub PR mode** (post review to PR). `--local` for single-pass terminal output. `--preflight` for multi-round review with auto-fix (min 3, max 5 rounds). `--autofix` for autonomous fix + approve. `--sweep` for iterative cleanup.

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

**Skip if `--sweep` or `--preflight`** - these modes operate on the current working directory against the default branch.

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
   - Severity: `critical` | `warning` | `nit` | `observation`
   - File + line range (omit line range for `observation` if it is file- or architecture-scoped)
   - Category (from list above)
   - Title (short)
   - Problem description (1-2 sentences)
   - Suggested fix (specific, minimal) - **omit for `observation`**; observations have no fix

   `observation` is reserved for architectural notes with no concrete fix. Max 2 per review. Observations are body-only prose in Reporting and do **not** enter the Verification stage. See the Verification section's "Observation severity" subsection for the full rule set.

5. **Pre-filter**: Drop findings that are:
   - Style nitpicks mis-classified as warnings → downgrade to nit or drop
   - Already caught by CI tooling (eslint, tsc, prettier) → drop
   - Missing a concrete, actionable fix → drop

---

## Verification

The core differentiator: every candidate finding is validated by a sub-agent that applies the fix and runs quality gates.

### Invariant (non-negotiable)

Every candidate finding that survives the pre-filter step in Analysis **MUST** be verified by its own isolated-worktree sub-agent that (i) applies the proposed fix and (ii) runs the full quality-gate suite. This is the property that distinguishes `/pst:code-review` from an opinion dump. Collapsing verification into a single shared worktree, skipping the fix-application step, or declaring findings "static-analysis-verifiable" to bypass this loop is **not permitted** - those rationales are rejected regardless of how sensible they sound in the moment.

The only exception is the `observation` severity (see below), which has no fix to apply and therefore no gate to run.

### Rejected rationales

The following shortcuts have all been proposed in the past and are **explicitly rejected**. If the sub-agent's reasoning matches any of these shapes, the run has failed its invariant and the final report must flag it as a failure mode, not a "defensible shortcut."

- _"`EnterWorktree` is a deferred tool requiring a schema fetch, so I used one shared worktree."_ → Wrong entry point. The `Task` tool with `isolation: "worktree"` is the mechanism, and `Task` is always live - no schema fetch required. Spawn with `Task({ subagent_type: "general-purpose", isolation: "worktree", run_in_background: true, prompt: ... })`.
- _"Each sub-agent would re-run `pnpm run worktree:init`, which is expensive given a shared environmental gap (e.g., missing service credentials, unreachable external providers)."_ → Cost of correctness. `node_modules` is typically hardlink/sparse-copied by the worktree harness, so re-bootstrap is cheap. Partial environment failures (e.g., a provider-specific codegen step unable to reach its dev backend) are acceptable and **must not** block verification of diffs that don't exercise the unavailable service. Run `worktree:init || true` and proceed; the gate-execution step already handles partial-gate scenarios.
- _"The findings are statically verifiable (schema orphans, stale comments, routing order, missing concurrency caps) - a single quality-gate pass covers them."_ → The per-finding gate is not only about build/runtime regression. It also cross-checks that (a) the finding correctly describes the target code, (b) the proposed fix is minimal and doesn't silently break surrounding tests or types, and (c) multiple independent findings don't have conflicting or overlapping fixes. Those properties **only** hold when each fix is applied in isolation.

### Observation severity (the single escape hatch)

For rare architectural notes that have no concrete fix ("consider splitting this module in a future pass", "this pattern is diverging from the rest of the codebase - worth a team discussion"), use the `observation` severity.

- Observations are **body-only prose** in the review summary - no inline comment, no fix block, no `suggestion` code block, no quality-gate claim.
- Observations are **excluded from per-finding verification** because they have no fix to apply.
- **Cap: at most 2 observations per review.** If you find yourself wanting to emit a 3rd, open a follow-up issue or ADR instead.

`observation` is the **only** valid path for a finding that does not run through isolated-worktree verification. Any other finding that skips the loop is a bug.

### Spawning sub-agents

**For EACH candidate finding** that survived the Analysis pre-filter and is **not** an `observation`, spawn a sub-agent:

```
Task:
  subagent_type: general-purpose
  description: "Verify finding R{N}: {title}"
  isolation: worktree
  run_in_background: true
  prompt: "<self-contained per-finding verification instructions>"
```

**All agents spawn simultaneously.** Each gets its own isolated worktree copy of the code.

### Sub-agent workflow (numbered - no step is optional unless noted)

1. **Bootstrap the worktree (best-effort).** If `package.json` has a `worktree:init` script (or equivalent name like `agent:init`, `bootstrap`), run it immediately after `cd`'ing into the worktree. **Do not fail on partial bootstrap** - missing env vars or unreachable external services are expected in verification worktrees:
   ```bash
   if grep -q '"worktree:init"' package.json 2>/dev/null; then
     $PKG_MANAGER run worktree:init || true
   else
     $PKG_MANAGER install --frozen-lockfile || true
   fi
   ```
   This installs deps, symlinks env files, and fixes husky hooks path where possible. Bootstrap failure is **not** grounds to skip steps 2–7. Carry on and let the gate-execution step in 6 handle what can and cannot run.
2. **Read the target file, surrounding code context, and trace the dependency graph.** Follow callers/callees until hitting system boundaries (API, DB, external service). Understand the blast radius.
3. **Validate against:** ADRs, patterns files, inferred patterns from the Analysis stage.
4. **Filter-discard check - DISCARD the finding (verdict: `DROPPED`) if:**
   - It's a style preference disguised as a warning (rename, blank line, import order).
   - It flags a phantom bug from incomplete context (e.g., non-null flagged as nullable when the type system guarantees it).
   - CI tooling would already catch it (eslint, tsc, prettier rules).
   - It's over-engineering (excessive abstraction, unnecessary error handling for impossible cases).
   - The fix would break existing tests or API contracts.
   - It doesn't materially affect reliability, correctness, or maintainability.

   This step may drop the finding **before** a fix is applied. It may **not** be used as a reason to skip step 5 for a finding that was not dropped here.

5. **Apply the suggested fix** in the worktree. Minimum edit - don't refactor beyond the finding. This is the step most likely to be skipped under time pressure or "static-analysis-verifiable" reasoning; skipping it invalidates the whole run.
6. **Run quality gates.** Detect the package manager, then execute:

   ```bash
   $PKG_MANAGER run build 2>&1
   $PKG_MANAGER run lint 2>&1
   $PKG_MANAGER run typecheck 2>&1
   $PKG_MANAGER run test 2>&1
   ```

   Gate-result classification:
   - **PASS:** command exits 0 after applying the fix.
   - **FAIL:** command exits non-zero and the same command also exits 0 on the unedited base commit. Verdict → `DROPPED`.
   - **N/A:** command exits non-zero on both the fix and the unedited base (environmental constraint, not a regression caused by the fix). Record the gate as N/A with the identical-failure evidence. N/A is acceptable but must be explicit and proven, not assumed.

   At least **one gate must execute to a PASS or a proven-N/A verdict**. If zero gates run (e.g., bootstrap totally failed and no gate command is invokable), the verdict is `DROPPED`.

7. **Produce a verdict:**
   - `VERIFIED` - the fix applied cleanly **and** every runnable gate either passed or is a proven N/A with evidence.
   - `DROPPED` - the finding was filtered in step 4, the fix could not apply cleanly, a gate failed only on the fixed tree, or zero gates were runnable.

   No other verdicts are valid. "Skipped for time," "covered by another finding," and "probably fine - it's just a comment" are all `DROPPED`.

**After all sub-agents complete:**

- Collect results. `VERIFIED` findings proceed to Reporting. `DROPPED` findings are recorded with a one-line reason for the Reporting stage's "Dropped during verification" section.
- Clean up all verification worktrees.
- Assert `VERIFIED + DROPPED == total non-observation candidates`. If the count doesn't balance, a sub-agent silently skipped the loop - treat the entire review as invalid and re-run the missing sub-agents before posting.

---

## Reporting

### Required review-body sections (GitHub PR bodies)

Every review body posted to GitHub - regardless of mode (default or `--autofix`) - **must** contain the following sections in this order:

1. **Summary** - max 8 bullets.
2. **Findings** - table of `VERIFIED` findings (critical / warning / nit).
3. **Observations** - the body-only prose list (0, 1, or 2 items; omit the section if empty).
4. **Dropped during verification** - enumerate every candidate finding that ended the Verification stage with a `DROPPED` verdict, one line each, with the one-line reason (filter-discard rule matched, gate regression, no gate runnable, etc.).
5. **Verification integrity** - a single assertion line: `VERIFIED (${V}) + DROPPED (${D}) = ${V+D} non-observation candidates.` This number **must** match the total candidates produced by Analysis after pre-filter. If it doesn't, the run is invalid.

### GitHub PR Mode (default)

Post a single grouped review via `gh api POST /repos/{owner}/{repo}/pulls/{N}/reviews`:

- Event: `REQUEST_CHANGES` if any critical finding, else `COMMENT`
- Body: the 5 required sections above, in order

Get `commit_id`: `gh pr view <N> --json headRefOid --jq .headRefOid` (validate `^[0-9a-f]{40}$`; fallback: `git rev-parse HEAD`; both fail → body-only review via `gh pr review`).

Write comments to a temp JSON file, pass via `--input`, clean up after.

**Capture the posted review's `html_url`** from the API response and immediately open it in the user's default browser so they can see it without leaving their workflow:

```bash
REVIEW_RESPONSE=$(gh api "/repos/{owner}/{repo}/pulls/{N}/reviews" --method POST --input "$TMP_JSON")
REVIEW_URL=$(echo "$REVIEW_RESPONSE" | jq -r '.html_url')

# Open in browser (cross-platform fallback chain)
if [ -n "$REVIEW_URL" ] && [ "$REVIEW_URL" != "null" ]; then
  if command -v open >/dev/null 2>&1; then
    open "$REVIEW_URL"           # macOS
    echo "Opened review in browser: $REVIEW_URL"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$REVIEW_URL"       # Linux
    echo "Opened review in browser: $REVIEW_URL"
  elif command -v start >/dev/null 2>&1; then
    start "$REVIEW_URL"          # Windows (Git Bash/WSL)
    echo "Opened review in browser: $REVIEW_URL"
  else
    echo "Review posted (no browser opener available): $REVIEW_URL"
  fi
fi
```

Fallback to `gh pr review` body-only mode: after posting, open the PR URL instead -- `open "$(gh pr view $N --json url --jq .url)"`. If the browser-open command itself fails (e.g., headless CI), print the URL prominently and continue -- never block on this.

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

### Local Mode (`--local`)

Same Analysis + Verification stages (single pass). Output findings to terminal with severity markers. No GitHub interaction. No code edits.

### Preflight Mode (`--preflight`)

Multi-round code review with auto-fix. No GitHub interaction. No AskUserQuestion calls (fully autonomous).

Preflight combines review + fix: it finds issues, verifies fixes in isolated worktrees, then applies all verified fixes directly. This is the recommended pre-push workflow.

**Constants:** `MIN_ROUNDS = 3`, `MAX_ROUNDS = 5`

**Round loop:**

1. Compute diff: `git diff $(git merge-base origin/$DEFAULT_BRANCH HEAD)...HEAD`
2. Run full Analysis + Verification (autonomous)
3. Collect VERIFIED findings (criticals + warnings only after round 1; include nits in round 1)
4. **Auto-apply all verified fixes** (they've already proven to pass quality gates in worktree verification)
5. If fixes were applied: `git add {fixed files}` (do NOT commit yet -- all rounds accumulate into one commit)
6. If `round >= MIN_ROUNDS` AND 0 new findings (criticals + warnings) on the updated diff -> print clean summary, exit loop
7. If findings remain AND `round < MAX_ROUNDS` -> narrow focus for next round:
   - Re-diff against the now-modified working tree
   - Exclude file+line combinations already fixed in prior rounds
   - Increase scrutiny: look deeper at blast radius, edge cases, concurrency, and error paths
   - Print round summary
8. If `round == MAX_ROUNDS` AND findings remain -> report remaining unfixed findings, exit loop

**After the round loop completes**, if any fixes were applied across all rounds:

```bash
git add {all fixed files from all rounds}
git commit -m "fix: preflight review findings

Applied {N} verified fixes across {M} rounds.
Findings: {summary of R-IDs and titles}

Co-Authored-By: Claude <noreply@anthropic.com>"
```

**Terminal output per round:**

```
PREFLIGHT ROUND {N}/{MAX}
Criticals: {n} | Warnings: {n} | Nits: {n}
New findings: {list of R-IDs} | Fixed: {list of R-IDs applied} | Cumulative: {total}
```

**Final summary:**

```
PREFLIGHT COMPLETE - {N} round(s), {total findings} found, {fixed count} auto-fixed
  Criticals: {n} | Warnings: {n} | Nits: {n}
  Fixed: {list of R-IDs} | Remaining: {list of R-IDs or "none"}
  Status: CLEAN|FINDINGS_REMAIN
```

All findings from all rounds are presented in the final terminal output, deduplicated and sorted by severity. Fixed findings are marked with a checkmark.

### Autofix Mode (`--autofix`)

- Fully autonomous (no AskUserQuestion calls)
- Auto-apply all verified fixes (they've already proven to pass quality gates)
- One squashed commit for all fixes
- If 0 criticals remain + PR exists → auto-post APPROVE via GitHub API
- After posting the review/approval, **open the review `html_url` in the browser** using the same `open`/`xdg-open`/`start` fallback chain described in GitHub PR Mode above. Never block on failure.

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

**Skip if `--sweep`, `--local`, or `--preflight`.**

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

| Condition                  | Action                                                                      |
| -------------------------- | --------------------------------------------------------------------------- |
| 401/403 from GitHub        | Instruct `gh auth login`                                                    |
| 422 (invalid line comment) | Remove invalid comments, retry                                              |
| 429 (rate limit)           | Wait, retry, fallback to body-only                                          |
| Empty diff                 | Exit with message                                                           |
| Sub-agent worktree failure | Verdict `DROPPED` for that finding (record reason). No "unverified" bypass. |
| All sub-agents fail        | Abort the review. Do not post "unverified" findings to the PR.              |
| Worktree creation fails    | Retry once; on second failure, abort the review with clear error.           |
| Worktree cleanup fails     | Warn with manual cleanup command                                            |
| Sweep max rounds exceeded  | Report remaining issues, exit                                               |

---

## Output contract

Every run - GitHub PR, `--local`, `--preflight`, `--autofix`, or `--sweep` - must emit, as the **final line** of the terminal / background-task output, the self-audit line:

```
Per-finding verification: ${VERIFIED}/${TOTAL} candidates ran isolated quality gates.
```

Where `TOTAL` is the count of non-`observation` candidates that survived Analysis pre-filter, and `VERIFIED` is the count that reached verdict `VERIFIED`. `DROPPED` candidates still count as having "run" the gate - what is being audited is whether the isolated-worktree loop was entered, not whether the finding survived.

If `VERIFIED + DROPPED < TOTAL` - i.e., any non-`observation` finding is missing its isolated sub-agent run - the agent **must** abort the run, re-dispatch the missing sub-agents, and re-emit the self-audit line only after every non-`observation` candidate has reached VERIFIED or DROPPED. Posting (or printing a final report) with a sub-1.0 ratio is not permitted. A ratio below 1.0 with any finding that never entered the loop means the skill's core invariant was violated.
