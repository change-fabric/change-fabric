---
name: pst:qa
description: Autonomous QA testing - synthesizes test plans from PR context, executes via browser automation, auto-judges pass/fail
argument-hint: "[PR-number | PR-URL] [--post-merge] [--guided] [--preflight] [--save-evidence]"
allowed-tools: Bash, Read, Edit, Grep, Glob, AskUserQuestion, Agent
---

# Autonomous QA Testing

Synthesize a test plan from PR context and code changes, then execute it via browser automation with auto-judged pass/fail verdicts. Evidence is captured per test case and results are posted to the PR. Supports both autonomous execution (default) and interactive guided mode.

---

## Input & Mode

<arguments> #$ARGUMENTS </arguments>

**Parse arguments (first match wins):**

1. Matches `https://github.com/.*/pull/\d+` → **PR URL** → extract PR number
2. Matches `^\d+$` → **PR number**
3. `--post-merge` flag: Force post-merge mode (skip PR context gathering)
4. `--guided` flag: Interactive mode - human performs steps, judges pass/fail
5. `--preflight` flag: Local-only mode - terminal output only, no artifacts saved to repo, no GitHub/Jira interaction
6. `--save-evidence` flag: Persist QA evidence to the repo (`.qa/` directory), commit, and push to the PR branch. Without this flag, evidence uses a temp directory and is cleaned up after the run.

**Defaults:** Autonomous execution, pre-merge mode.

**If no arguments provided:**

1. Check for an open PR on the current branch: `gh pr view --json number,baseRefName 2>/dev/null`
2. If found → confirm: "Run QA for PR #N? [Y/n]"
3. If not found → ask: "Which PR would you like to QA?"

---

## PR Resolution

**Skip if `--post-merge`.**

**If PR number or URL provided:**

```bash
gh pr view $PR_NUMBER --json number,baseRefName,headRefName,title,url,state,body
```

Store `PR_NUMBER`, `BASE_BRANCH`, `HEAD_BRANCH`.

If state is `MERGED` or `CLOSED` → switch to post-merge mode automatically.

**If no PR resolved yet**, check for an open PR on the current branch:

```bash
gh pr view --json number,baseRefName,headRefName,title,url,state,body 2>/dev/null
```

If found → store PR metadata. If not found → use **AskUserQuestion**:

```
No open PR found for this branch.

Options:
1. Pre-merge - I'll create a PR later
2. Post-merge - the feature is already merged
3. Abort
```

**Stacked PR detection**: If `BASE_BRANCH` differs from the repo's default branch:

```
Note: Stacked PR detected - PR #{N} will be diffed against {BASE_BRANCH}, not the default branch.
```

---

## Workspace Setup

**Skip if:**

- `--post-merge` (testing merged code on current branch)
- No `HEAD_BRANCH` resolved

**Resolve HEAD SHA:**

```bash
HEAD_SHA=$(gh pr view $PR_NUMBER --json headRefOid --jq .headRefOid)
```

**Skip worktree if:**

1. Current branch matches `$HEAD_BRANCH`
2. `HEAD` matches `$HEAD_SHA`

**Otherwise:**

```bash
REPO_ROOT=$(git rev-parse --path-format=absolute --git-common-dir | sed 's|/.git$||')
git fetch origin "$HEAD_BRANCH"
QA_DIR="$REPO_ROOT/.worktrees/qa-PR-$PR_NUMBER"
```

If `QA_DIR` already exists, ask via **AskUserQuestion**:

```
Existing QA worktree found at $QA_DIR.

Options:
1. Reuse (dependencies already installed)
2. Recreate (fresh)
3. Abort
```

If recreating or new:

```bash
git worktree remove --force "$QA_DIR" 2>/dev/null
git worktree add --detach "$QA_DIR" "$HEAD_SHA"
```

Set `QA_WORKTREE=true`, work from `$QA_DIR` for all subsequent stages.

---

## Context Gathering

Gather all available context to build a test plan. No external project management tools - everything comes from the repo and PR.

**1. PR Description**

Extract QA-relevant content from the PR body:

- "How to Test" or "Testing" sections
- Bullet points describing behavior changes
- Checkbox items (`- [ ]`)
- Screenshots or recordings mentioned
- Known limitations or caveats

**PR Checkbox Tracking:**

Parse all unchecked checkboxes (`- [ ] ...`) from the PR body. Store them in a tracking list:

```
PR_CHECKBOXES = [
  { index: 0, text: "Verify login works with valid credentials", checked: false },
  { index: 1, text: "Error message shows for invalid email", checked: false },
  ...
]
```

The `index` is the positional occurrence of the checkbox in the full PR body (0-based), used later to update the correct checkbox. Each checkbox becomes a candidate test case with `Source: PR checkbox`.

**2. Git Diff (pre-merge only)**

```bash
MERGE_BASE=$(git merge-base HEAD "origin/$BASE_BRANCH")
git diff --stat $MERGE_BASE...HEAD
git diff --name-only $MERGE_BASE...HEAD
```

Categorize changed files:

| Category | Signals                                                       |
| -------- | ------------------------------------------------------------- |
| UI       | `*.tsx`, `*.vue`, `*.svelte`, `components/`, `pages/`, `app/` |
| API      | `api/`, `routes/`, `controllers/`, `services/`                |
| DB       | `migrations/`, `schema.*`, `prisma/`, `drizzle/`, `models/`   |
| Config   | `*.config.*`, `.env*`, `docker*`, `.github/`                  |
| Tests    | `__tests__/`, `*.test.*`, `*.spec.*`, `test/`                 |

**3. Existing Test Files**

```bash
find .qa/ -name '*plan*' -o -name '*test*' -o -name '*spec*' 2>/dev/null
```

Read and extract any prior test-relevant content.

**4. Commit Messages**

```bash
git log --oneline $MERGE_BASE...HEAD
```

Understand the narrative of the changes.

**5. Missing Context**

If no PR description and no clear testable surface from the diff → use **AskUserQuestion**:

```
Limited context available. What should QA focus on?

Options:
1. Extract testable areas from the code diff
2. I'll describe what to test
3. Abort
```

---

## Test Plan

**Synthesis**

Combine test cases from all context sources:

- PR description testing notes (primary)
- Git diff categories (identify untested areas)
- Commit message narrative
- Existing test specs

**Deduplication**

When multiple sources describe the same test, keep the most specific version. Prefer PR description wording as canonical. When a PR checkbox is kept as the canonical version, preserve its `PR_CHECKBOXES` index in the test case metadata so it can be checked off later.

**Prioritization**

| Priority | Category                    | Always Include?         |
| -------- | --------------------------- | ----------------------- |
| P1       | Critical path / happy path  | Yes                     |
| P2       | Error handling / validation | If guided or autonomous |
| P3       | Edge cases                  | If autonomous           |
| P4       | Regression (related areas)  | If autonomous           |
| P5       | Non-functional (perf, a11y) | Autonomous only         |

In `--guided` mode, default to P1-P2 unless the tester requests more.

**Test Case Format**

```
TC-{N}: {Title}
Source: {PR description | PR checkbox | Git diff | Commit message | Manual input}
PR Checkbox Index: {index from PR_CHECKBOXES, or "N/A"}
Priority: {P1-P5}
Preconditions: {any setup needed}
Steps:
  1. {action}
  2. {action}
Expected Result: {what should happen}
Test Data: {specific data needed, or "N/A"}
```

**Confirmation**

**If autonomous:** Log test plan summary (count, priorities) but skip confirmation. Proceed to Environment Bootstrap.

**If guided**, present via **AskUserQuestion**:

```
TEST PLAN - PR #{N}
─────────────────

Mode: {pre-merge|post-merge}
Environment: {local bootstrap|URL}
Test cases: {N total} (P1: X, P2: Y, P3: Z)

  #   Title                                  Priority  Source
  1   User can create account                P1        PR description
  2   Error shown for duplicate email        P2        Git diff
  3   Form validates required fields         P2        Git diff
  ...

Options:
1. Start testing
2. Add or remove test cases
3. Edit a test case
4. Abort
```

---

## Environment Bootstrap

**Skip if the tester provides an external URL.**

**Back up environment files:**

```bash
if [ -f .env.local ]; then
  ENV_BACKUP=".env.local.qa-backup-$$"
  cp .env.local "$ENV_BACKUP"
fi
```

**Install dependencies:**

Detect package manager (pnpm > yarn > npm) and install:

```bash
$PKG_MANAGER install
```

**Start application:**

Ask via **AskUserQuestion** if no common start script is detected:

```
How should the application be started?

Options:
1. npm run dev / pnpm dev
2. Custom command (provide)
3. Already running at a URL (provide)
4. Abort
```

Select a random available port:

```bash
QA_PORT=$(node -e "const s=require('net').createServer();s.listen(0,()=>{console.log(s.address().port);s.close()})")
PORT=$QA_PORT $START_COMMAND &
APP_PID=$!
```

**Health check:**

Poll `http://localhost:$QA_PORT/` every 2 seconds for up to 30 seconds:

```bash
for i in $(seq 1 15); do
  curl -sf "http://localhost:$QA_PORT/" > /dev/null 2>&1 && break
  sleep 2
done
```

If timeout → offer retry, external URL, or abort.

Set `QA_URL=http://localhost:$QA_PORT`.

---

## Test Execution

### Browser Tier Selection

Resolve once before the first test case. Check in order - first available wins:

| Tier | Method         | Detection                                       | When                       |
| ---- | -------------- | ----------------------------------------------- | -------------------------- |
| 0    | Playwright MCP | `mcp__playwright__browser_navigate` is callable | Preferred - headless, fast |
| 1    | CDP bridge     | Script exists at resolved path                  | Fallback - visible Chrome  |
| 2    | Manual / human | Neither available                               | Last resort                |

**Resolve CDP bridge path:**

```bash
# Follow symlink from installed skill back to source
SKILL_LINK="$HOME/.claude/commands/pst:qa.md"
if [ -L "$SKILL_LINK" ]; then
  SKILL_REAL=$(readlink -f "$SKILL_LINK")
  CDP_BRIDGE="$(dirname "$SKILL_REAL")/scripts/cdp-bridge.js"
fi
```

If `--guided` → always use Tier 1 (visible Chrome) when available; fall back to Tier 2.

### CDP Setup (Tier 1 only)

```bash
CDP_LAUNCH=$(node "$CDP_BRIDGE" launch --url "$QA_URL")
CDP_PID=$(echo "$CDP_LAUNCH" | node -e "process.stdin.on('data',d=>{const j=JSON.parse(d);console.log(j.chromePid)})")
CDP_PORT=$(echo "$CDP_LAUNCH" | node -e "process.stdin.on('data',d=>{const j=JSON.parse(d);console.log(j.port)})")
CDP_PROFILE=$(echo "$CDP_LAUNCH" | node -e "process.stdin.on('data',d=>{const j=JSON.parse(d);console.log(j.tempDir)})")
```

Start event stream:

```bash
node "$CDP_BRIDGE" stream --port $CDP_PORT --output /tmp/pst-qa-cdp-$(date +%s).jsonl &
CDP_STREAM_PID=$!
```

### Playwright Setup (Tier 0 only)

When using Playwright MCP, skip CDP launch entirely. Navigate to `$QA_URL` before the first test case.

Playwright MCP tools reference:

- `mcp__playwright__browser_navigate` - navigate to URLs
- `mcp__playwright__browser_click` - click elements
- `mcp__playwright__browser_fill_form` - fill form fields
- `mcp__playwright__browser_type` - type text
- `mcp__playwright__browser_press_key` - press keys
- `mcp__playwright__browser_take_screenshot` - capture evidence
- `mcp__playwright__browser_wait_for` - wait for async updates
- `mcp__playwright__browser_snapshot` - accessibility tree for DOM verification
- `mcp__playwright__browser_evaluate` - run JS assertions
- `mcp__playwright__browser_drag` - drag-and-drop
- `mcp__playwright__browser_hover` - hover
- `mcp__playwright__browser_select_option` - dropdowns

If any Playwright tool fails with tool-not-found → fall back to Tier 1 (CDP) for remaining tests.

### Evidence Directory

**If `--save-evidence` (and not `--preflight`):**

```bash
QA_EVIDENCE_DIR=".qa/pr-${PR_NUMBER}"
mkdir -p "$QA_EVIDENCE_DIR"
```

For post-merge: `.qa/post-merge-$(date +%Y%m%d)/`

**Otherwise (default):** Use a temporary directory for evidence (screenshots needed for auto-judging but not persisted):

```bash
QA_EVIDENCE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pst-qa-XXXXXX")
```

### Progress Checkpoint

Create before the first test case:

```json
{ "done": [], "todo": [1, 2, 3], "verdicts": {}, "qaUrl": "...", "cdpPort": 0 }
```

Save to `$QA_EVIDENCE_DIR/progress.json`. Update after each test case completes.

**Recovery after context compression:** If you find yourself mid-execution, read `progress.json` immediately. The `todo` array tells you exactly which test cases remain. Resume without asking.

### Autonomous Execution (default)

**CRITICAL - COMPLETION MANDATE:** Execute ALL test cases without stopping. Do NOT pause or end your turn until every test case is done and Cleanup + Report stages are complete. The ONLY reason to stop is a fallback-to-human scenario.

**Pre-test check (Tier 1 - CDP):**

```bash
grep '"exception"' "$CDP_JSONL" | tail -5
grep '"status":4[0-9][0-9]\|"status":5[0-9][0-9]' "$CDP_JSONL" | tail -5
```

Log warnings if errors found.

**For each test case TC-N:**

**Step 1 - Execute steps.**

Tier 0 (Playwright):

- Use `browser_snapshot` to find element references
- Use `browser_click`, `browser_fill_form`, `browser_type` with refs
- Use `browser_wait_for` after navigation/state changes

Tier 1 (CDP):

- Navigate → `node "$CDP_BRIDGE" run --port $CDP_PORT --type navigate --url "$URL"`
- Click → `run --type evaluate --expr "document.querySelector('$S').click()"` or `run --type click --x $X --y $Y`
- Type → `run --type focus --selector "$S"` + `run --type type --text "$TEXT"`
- Wait → check URL via `capture --port $CDP_PORT --type url`

**Step 2 - Capture evidence.**

Tier 0: `browser_take_screenshot` → save to `$QA_EVIDENCE_DIR/tc${N}-result.png`
Tier 1:

```bash
node "$CDP_BRIDGE" capture --port $CDP_PORT --type screenshot --save "$QA_EVIDENCE_DIR/tc${N}-result.png"
node "$CDP_BRIDGE" capture --port $CDP_PORT --type dom
node "$CDP_BRIDGE" capture --port $CDP_PORT --type url
```

**Step 3 - Auto-judge.**

Compare actual state against expected result:

- Check DOM content for expected text/elements
- Check URL for expected navigation
- Check for console errors or network failures
- Check screenshot against expected visual state

Verdicts: `pass` | `fail` | `skip` (precondition not met)

**Step 4 - Record.**

Update `progress.json`. Log to terminal:

```
TC-{N}: {title} - {PASS|FAIL|SKIP}
  {brief explanation if fail/skip}
```

**Fallback to human:** If stuck (can't find element, login wall, CAPTCHA, out-of-browser action, ambiguous result, CDP/Playwright error after retry) → use **AskUserQuestion** with the current state and ask the human to perform the step and report the result.

### Guided Execution (`--guided`)

Present each test case one at a time via **AskUserQuestion**:

```
TC-{N}: {title}
Priority: {P1-P5}

Steps:
  1. {action}
  2. {action}

Expected Result: {what should happen}

Options:
1. Pass
2. Fail (describe what happened)
3. Skip
4. Abort remaining tests
```

If CDP is available (Tier 1), offer co-pilot assistance:

```
Would you like me to execute this step via browser automation?

Options:
1. Yes, execute it
2. No, I'll do it manually
```

---

## Cleanup

Run cleanup regardless of test outcome.

**Kill application:**

```bash
if [ -n "$APP_PID" ]; then
  kill $APP_PID 2>/dev/null
  wait $APP_PID 2>/dev/null
fi
```

**Teardown CDP (Tier 1):**

```bash
node "$CDP_BRIDGE" teardown --pid $CDP_PID --stream $CDP_STREAM_PID --profile "$CDP_PROFILE" --output "$CDP_JSONL"
```

**Restore environment:**

```bash
if [ -n "$ENV_BACKUP" ] && [ -f "$ENV_BACKUP" ]; then
  mv "$ENV_BACKUP" .env.local
fi
```

**Remove worktree:**

If `QA_WORKTREE=true`:

```bash
cd "$REPO_ROOT"
git worktree remove --force "$QA_DIR"
```

If removal fails, warn with manual cleanup command.

---

## Report & Evidence

### Preflight Mode (`--preflight`)

**Skip** all artifact persistence and external interaction (Write Report, Commit Evidence, Post PR Comment, Update PR Checkboxes). Instead:

**1. Print the full report to terminal** using the same markdown format as the report file (summary table + per-test-case results with verdicts and failure details).

**2. Suggest next step** based on results:

- **All pass:** "All tests passed. Run `/pst:qa` (without `--preflight`) to save evidence and post results to the PR."
- **Any fail:** "Failures detected. Fix the issues above, then re-run `/pst:qa --preflight` to verify before posting."
- **All skip:** "All tests were skipped. Check preconditions and environment setup."

**3. Clean up temp evidence directory:**

```bash
rm -rf "$QA_EVIDENCE_DIR"
```

**4. Print the Output Contract** (with `evidence: none (preflight)`, `github-comment: skipped (preflight)`, `pr-checkboxes: skipped (preflight)`), then stop.

### Default Mode (no `--save-evidence`, no `--preflight`)

Runs the full QA flow including PR comment and checkbox updates, but does **not** persist evidence in the repo. After reporting:

**1. Clean up temp evidence directory:**

```bash
rm -rf "$QA_EVIDENCE_DIR"
```

**2. Print Output Contract** with `evidence: none (temp, cleaned up)`.

---

### Write Report

**Skip unless `--save-evidence` is set (and not `--preflight`).**

Generate `$QA_EVIDENCE_DIR/report.md`:

```markdown
# QA Report - PR #{N}

**Date:** {ISO date}
**Mode:** {pre-merge|post-merge}
**Execution:** {autonomous|guided}
**Result:** {PASSED|FAILED|PARTIAL}

## Summary

| Total | Pass | Fail | Skip |
| ----- | ---- | ---- | ---- |
| {N}   | {M}  | {K}  | {J}  |

## Results

### TC-1: {title} - PASS

Evidence: tc1-result.png

### TC-2: {title} - FAIL

**Actual:** {what happened}
**Expected:** {what should have happened}
Evidence: tc2-result.png

...
```

### Commit Evidence (pre-merge only)

**Skip unless `--save-evidence` is set (and not `--preflight`).**

If there are screenshots or report files:

```bash
git add "$QA_EVIDENCE_DIR"
git commit -m "qa: evidence for PR #${PR_NUMBER}"
```

Push evidence to the PR branch so it's accessible:

```bash
git push origin HEAD:refs/heads/$HEAD_BRANCH
```

### Post PR Comment

**Skip if `--preflight`.**

If a PR exists and mode is not `--post-merge`:

```bash
gh pr comment $PR_NUMBER --body "$(cat <<'EOF'
## QA Results - {PASSED|FAILED|PARTIAL}

| Total | Pass | Fail | Skip |
|-------|------|------|------|
| {N}   | {M}  | {K}  | {J}  |

{Brief summary of failures if any}

<details>
<summary>Full Results</summary>

{Per test case: TC-N: title - verdict}

</details>

{If --save-evidence: "Evidence committed to branch: `{HEAD_BRANCH}`" | Otherwise: omit this line}
EOF
)"
```

### Update PR Checkboxes

**Skip if:** `--post-merge`, `--preflight`, `--local`, or no PR exists.

After posting the QA comment, check off any PR description checkboxes whose corresponding test cases passed.

**Step 1 - Identify passed checkboxes:**

From the test results, collect all test cases that:

- Have a verdict of `pass`
- Have a `PR Checkbox Index` that is not `N/A`

**Step 2 - Fetch current PR body:**

```bash
PR_BODY=$(gh pr view $PR_NUMBER --json body --jq .body)
```

**Step 3 - Replace checkboxes:**

For each passed checkbox index, replace the Nth unchecked checkbox (`- [ ]`) with a checked one (`- [x]`). Process replacements from highest index to lowest to preserve positional accuracy.

**Step 4 - Update PR description:**

Use the GitHub API to update the PR body (avoids token scope issues with `gh pr edit`):

```bash
gh api repos/{owner}/{repo}/pulls/$PR_NUMBER --method PATCH --field body="$UPDATED_BODY"
```

**Step 5 - Log result:**

```
PR checkboxes updated: {N} of {total} checked off
```

If any checkbox's test case failed or was skipped, leave it unchecked.

### Output Contract

Always print this block at the end for machine parsing:

```
--- QA RESULT ---
pr: #{N}
mode: {pre-merge|post-merge}
execution: {autonomous|guided}
result: {PASSED|FAILED|PARTIAL}
total: {N} | pass: {M} | fail: {K} | skip: {J}
evidence: {path to report (--save-evidence) | none (default, cleaned up) | none (preflight)}
github-comment: {posted|skipped}
pr-checkboxes: {N checked}/{total found}
--- END QA RESULT ---
```
