---
name: pst:auto
description: High-autonomy orchestrator - rough prompt to review-ready PR with minimal interaction
argument-hint: "[unstructured request]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, AskUserQuestion, Skill
---

# Autonomous Feature Orchestrator

Accept an unstructured request, ask a small number of clarifying questions, then execute end-to-end autonomously: implement, refine, quality-gate, review, QA, push, and open a review-ready PR in the browser.

---

## State Machine

```
intake -> clarify -> plan -> implement -> refine -> quality-gates ->
review-loop -> qa -> push-pr -> final-review -> done
                                                    \-> blocked (from any state)
```

Transitions back are allowed:

- `review-loop -> implement` if findings require code changes
- `qa -> implement` if bugs are found
- `final-review -> push-pr` if last-minute fixes were applied

---

## Progress Tracking

Write `.pst-auto-progress.json` at the repo root after each phase completes. Add the file to `.git/info/exclude` so it is never committed.

```json
{
  "state": "implement",
  "feature": "short description",
  "branch": "feature/slug",
  "plan": { "problem": "...", "criteria": "...", "skills": ["..."] },
  "completed": ["intake", "clarify", "plan"],
  "skipped": [],
  "pr_number": null,
  "pr_url": null,
  "residual": []
}
```

**Recovery:** If `.pst-auto-progress.json` exists when the skill starts, read it. Resume from the first phase NOT in `completed` or `skipped`. Do NOT re-run the interview.

---

## Phase 1 -- Intake, Clarify, Plan (INTERACTIVE)

This is the only phase where normal user interaction is expected.

### 1A. Intake

Parse the raw request from `$ARGUMENTS`:

<arguments> #$ARGUMENTS </arguments>

If no arguments provided, use **AskUserQuestion** once: "What are we building?"

Gather context silently (no questions):

```bash
BRANCH=$(git branch --show-current 2>/dev/null)
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
STATUS=$(git status --porcelain 2>/dev/null)
```

Also read:

- `CLAUDE.md` / `.claude/CLAUDE.md` if present
- `.context/**` if present
- `package.json` (scripts, dependencies, framework detection)
- `gh pr view --json number,url,state 2>/dev/null` (existing PR?)
- `git log --oneline -10` (recent commit style)
- High-level project structure via Glob (`src/**`, `app/**`, `pages/**`)

Detect: package manager, framework (Next.js, React, Node, etc.), test framework, available quality scripts (build, lint, typecheck, test, test:coverage).

### 1B. Clarify

Use **AskUserQuestion** to ask **up to 3** high-value questions, one at a time. Target only strategy-critical ambiguity:

1. Desired end state if the prompt could imply multiple valid outcomes
2. Scope boundary if the request is broad
3. Preference between two materially different implementation directions

**Rules:**

- Do NOT ask obvious questions answerable from the repo
- Do NOT ask implementation trivia (naming, file locations, patterns)
- Do NOT keep interviewing indefinitely -- 3 questions maximum
- If the user says "you decide", proceed and record the decision in the plan

### 1C. Plan Freeze

After clarification, write an internal execution plan:

```
EXECUTION PLAN
--------------
Problem:  {one sentence}
Success criteria:
  - {criterion 1}
  - {criterion 2}
Affected areas:
  - {file/directory 1} -- {what changes}
  - {file/directory 2} -- {what changes}
Skills to invoke:
  - validate-quality-gates
  - pst:slop --auto
  - pst:react-refactor (if TSX changed)
  - pst:code-review --preflight (review loop)
  - pst:push
  - pst:qa (if user-facing surface)
  - pst:code-review --autofix (final review)
```

Print the plan to the terminal. **Do NOT ask for approval.** Proceed immediately into autonomous execution.

Write `.pst-auto-progress.json` with state `implement`. Add to `.git/info/exclude`:

```bash
grep -qxF '.pst-auto-progress.json' .git/info/exclude 2>/dev/null || echo '.pst-auto-progress.json' >> .git/info/exclude
```

---

## Phase 2 -- Repo Assessment (AUTONOMOUS)

Before editing, inspect:

1. Current branch -- if on default branch, create `feature/{slug}` derived from the request
2. Uncommitted changes -- work with them when safe; do not revert user changes
3. Existing PR status via `gh pr view`
4. Changed files vs default branch
5. Available scripts in `package.json`

**Branch creation** (if on default branch):

```bash
SLUG=$(echo "$FEATURE_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | head -c 50)
git checkout -b "feature/$SLUG"
```

If already on a feature branch, stay on it.

**Infer mode from git state + prompt:**

- Clean branch with 0 commits ahead -> "new feature"
- Dirty branch or commits ahead -> "repair / polish existing work"
- Prompt says "fix", "finish", "get ready for review" -> "polish current branch"

---

## Phase 3 -- Spec & Decision Support (AUTONOMOUS)

Use existing skills selectively:

- If the task is STILL underspecified after the initial clarification, borrow `/spec-gen` behavior internally: fill in missing implementation details using what the codebase tells you. Do NOT enter an interview loop.
- If there are multiple viable implementation approaches, borrow `/decide-for-me` logic internally: pick the simplest, most reliable, most maintainable option. Do not ask.

This phase is silent -- no user interaction. Record decisions in the progress file.

---

## Phase 4 -- Implementation (AUTONOMOUS)

Perform the actual coding work.

**Requirements:**

1. Make the code changes needed to satisfy the plan
2. Follow existing codebase patterns (detected in Phase 1A)
3. Follow `CLAUDE.md` and project conventions
4. Create test files alongside implementation, not as a separate phase
5. Commit in logical units (2-5 commits for a typical feature)

```bash
git add <specific files>
git commit -m "<descriptive message>

Co-Authored-By: Claude <noreply@anthropic.com>"
```

**If a Figma URL was provided:** invoke `Skill("pst:figma", "<url>")` for UI implementation.

**Decision points** (no human input -- use project conventions):

- File locations: follow existing project structure
- Naming: match existing patterns
- Tests: match existing test framework and patterns
- Ambiguity: pick simplest option, note it in progress

Update progress: `"state": "refine"`.

---

## Phase 5 -- Refine (AUTONOMOUS)

### 5A. React Refactor (conditional)

**Run when:**

- The task changed `.tsx` files
- Components contain mixed rendering + business logic
- The branch would materially benefit from extracting hooks

**Skip when:**

- Backend-only task
- React edits are trivial (styling, copy, imports)
- Extraction would create churn without meaningful quality gain

```bash
MERGE_BASE=$(git merge-base "origin/$DEFAULT_BRANCH" HEAD)
TSX_CHANGES=$(git diff --name-only "$MERGE_BASE"...HEAD -- '*.tsx' | wc -l | tr -d ' ')
```

If warranted: `Skill("pst:react-refactor")`

### 5B. Slop Sweep (always)

The skill itself generated code, so always clean up:

```
Skill("pst:slop", "--auto")
```

If fixes were applied, commit:

```bash
git add -A
git commit -m "clean: remove AI-generated slop

Co-Authored-By: Claude <noreply@anthropic.com>"
```

Update progress: `"state": "quality-gates"`.

---

## Phase 6 -- Quality Gates (AUTONOMOUS)

```
Skill("validate-quality-gates")
```

Runs build, lint, typecheck, test, test:coverage in a loop until all pass or a blocker is found.

**If no quality scripts exist:** Skip, note in progress `skipped` array.

**If a real blocker persists after the skill's internal retries:** Log the failure, continue to review loop. The review or QA phase may surface the root cause.

Update progress: `"state": "review-loop"`.

---

## Phase 7 -- Review Loop (AUTONOMOUS)

Pre-push local code review with iterative fix cycles.

**Constants:** `MIN_ROUNDS = 2`, `MAX_ROUNDS = 5`

**Round loop:**

1. Run: `Skill("pst:code-review", "--preflight")`
2. Read the findings from terminal output
3. If verified critical or warning findings exist:
   - Apply the suggested fixes
   - Commit fixes:
     ```bash
     git add <fixed files>
     git commit -m "fix: address preflight review round N findings

     Co-Authored-By: Claude <noreply@anthropic.com>"
     ```
   - Re-run: `Skill("validate-quality-gates")`
4. If `round >= MIN_ROUNDS` AND 0 criticals AND 0 warnings remaining -> exit loop
5. If `round == MAX_ROUNDS` AND issues remain -> log residual findings, exit loop

**Sweep shortcut:** If the code-review skill supports `--sweep`, use `Skill("pst:code-review", "--preflight --sweep")` instead of the manual loop. The sweep mode internally handles min/max rounds.

Update progress: `"state": "qa"`.

---

## Phase 8 -- QA (AUTONOMOUS, CONDITIONAL)

**Run when:**

- There is a user-facing behavior change
- The task affects flows exercisable in a browser
- The repo has a runnable dev server (`dev` script in `package.json`)

**Skip when:**

- Purely internal / library-level task
- No runnable app or test surface
- No UI files changed

Detection:

```bash
UI_FILES=$(git diff --name-only "$MERGE_BASE"...HEAD -- '*.tsx' '*.jsx' '*.vue' '*.svelte' | wc -l | tr -d ' ')
HAS_DEV=$(node -e "const p=require('./package.json');console.log(p.scripts?.dev?'yes':'no')" 2>/dev/null)
```

If applicable: `Skill("pst:qa", "--preflight")`

Use `--preflight` since the PR does not exist yet. Feed QA failures back into implementation:

- If bugs found: fix them, re-run `Skill("validate-quality-gates")`, update progress
- If all pass: continue

If not applicable: note in `skipped` array.

Update progress: `"state": "push-pr"`.

---

## Phase 9 -- Push & PR (AUTONOMOUS)

```
Skill("pst:push")
```

This handles:

1. Auto-commit remaining uncommitted changes
2. Push with `--force-with-lease`
3. Create or update PR with full branch context
4. Refresh PR title and description from all commits
5. Validate test-plan checkboxes

**Capture PR number and URL** from the output. Parse the `--- PUSH RESULT ---` block or read from `gh pr view --json number,url`.

Update progress with `pr_number` and `pr_url`. Set `"state": "final-review"`.

---

## Phase 10 -- Final Review (AUTONOMOUS)

Run one PR-aware review pass on the pushed state:

```
Skill("pst:code-review", "--autofix <PR_NUMBER>")
```

The `--autofix` flag applies all verified fixes and posts an APPROVE review if 0 criticals remain.

**If fixes were applied:**

1. Re-run: `Skill("validate-quality-gates")`
2. Re-run: `Skill("pst:push")` to push fixes and update PR

**If no fixes needed:** Continue to completion.

Update progress: `"state": "done"`.

---

## Completion

All of the following must be true (unless impossible in the target repo):

1. Implementation completed
2. Available quality gates passing
3. Slop cleanup completed
4. React refactor completed where relevant
5. Preflight review loop completed
6. QA completed or explicitly skipped with reason
7. PR updated and current
8. Final review pass clean or only low-signal residual nits remain

**Open PR in browser:**

```bash
PR_URL=$(gh pr view --json url --jq .url 2>/dev/null)
if [ -n "$PR_URL" ]; then
  open "$PR_URL"
fi
```

**Clean up progress file:**

```bash
rm -f .pst-auto-progress.json
```

**Print output contract:**

```
AUTO RUN COMPLETE
-----------------
Implemented:
  - {bullet 1}
  - {bullet 2}

Checks passed:
  - {build | lint | typecheck | test | test:coverage | N/A}

Review:
  - Preflight sweep: {N rounds, M fixes | clean}
  - Final PR review: {clean | N fixes applied}

QA:
  - {Autonomous run completed | Skipped: reason}

PR:
  - #{N}
  - {URL}
  - Opened in browser

Residual notes:
  - {Any remaining caveats, or "None"}
```

---

## When to Ask the User Again

After plan freeze, only interrupt execution if:

1. A destructive decision is required (e.g., must delete or overwrite unrelated work)
2. Credentials or secrets are missing and cannot be inferred
3. Irreconcilable product ambiguity blocks implementation
4. The repo is in a conflicting state that cannot be safely resolved

Otherwise keep going autonomously. Prefer making a reasonable decision and noting it over asking.

---

## Safety

1. Never revert unrelated user changes
2. Never use destructive git commands (reset --hard, push --force, checkout .) unless explicitly requested
3. Always use `git push --force-with-lease` instead of `--force`
4. Max review loop rounds (5) prevent infinite cycles
5. Clearly report skipped phases and their reasons
6. Do not pretend checks passed when they did not
7. Do not merge the PR -- leave it for human review
