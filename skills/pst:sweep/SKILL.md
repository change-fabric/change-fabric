---
name: pst:sweep
description: Parallel quality sweep across open PRs -- resolve threads, code review, and QA in isolated worktrees, with optional author/label filtering
argument-hint: "[--author <login>] [--label <name>] [--cap N] [--dry-run] [--stages resolve,review,qa]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, AskUserQuestion, Skill
---

# Sweep -- Parallel Quality Pipelines Across Open PRs

Orchestrator that discovers open PRs, then fans out parallel quality pipelines (resolve-threads, code-review, QA) across all of them in isolated worktrees. Each PR gets its own agent. Filter by author, label, or any combination.

---

## Arguments

<arguments> #$ARGUMENTS </arguments>

**Parse arguments:**

- `--author <login>` -- only sweep PRs authored by this GitHub user (case-insensitive match)
- `--label <name>` -- only sweep PRs with this label
- `--cap N` -- override concurrency cap (max parallel pipelines, default 3)
- `--dry-run` -- discover and classify PRs but do not run pipelines
- `--stages <list>` -- comma-separated pipeline stages to run (default: `resolve,review,qa`). Valid stages: `resolve`, `review`, `qa`
- `--no-drafts` -- exclude draft PRs (default: drafts ARE included)
- No arguments -- sweep all open PRs with default pipeline

Multiple filters combine as AND (e.g., `--author pat --label bug` = PRs by pat with label bug).

Examples:

- `/pst:sweep` -- all open PRs, full pipeline
- `/pst:sweep --author pstaylor-patrick` -- only my PRs
- `/pst:sweep --label "needs review"` -- only PRs with that label
- `/pst:sweep --stages review,qa` -- skip resolve-threads
- `/pst:sweep --cap 2 --dry-run` -- preview what would be swept
- `/pst:sweep --no-drafts` -- skip draft PRs

---

## Phase 0: Guards & Config

```bash
BRANCH=$(git branch --show-current 2>/dev/null)
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
OWNER_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
OWNER=$(echo "$OWNER_REPO" | cut -d/ -f1)
REPO=$(echo "$OWNER_REPO" | cut -d/ -f2)
```

| Condition              | Action                               |
| ---------------------- | ------------------------------------ |
| `gh` not available     | Stop: "GitHub CLI (gh) is required." |
| `gh auth status` fails | Stop: "Run `gh auth login` first."   |

**Parse config:**

```
CONCURRENCY_CAP = args --cap N || 3
STAGES = args --stages || "resolve,review,qa"
AUTHOR_FILTER = args --author || ""
LABEL_FILTER = args --label || ""
INCLUDE_DRAFTS = !(args --no-drafts)
DRY_RUN = args --dry-run
```

Validate:

- `CONCURRENCY_CAP` must be a positive integer, max 10
- `STAGES` must be a comma-separated subset of: `resolve`, `review`, `qa`

---

## Phase 1: PR Discovery

**1.1 Fetch open PRs**

```bash
gh pr list --state open --json number,title,headRefName,baseRefName,url,isDraft,author,labels,reviewDecision --limit 100
```

Each PR has: `{number, title, headRefName, baseRefName, url, isDraft, author.login, labels[].name, reviewDecision}`

**1.2 Apply filters**

Starting from the full list, apply filters sequentially:

1. **Draft filter:** If `--no-drafts`, remove PRs where `isDraft=true`. Otherwise keep all.
2. **Author filter:** If `--author` provided, keep only PRs where `author.login` matches (case-insensitive).
3. **Label filter:** If `--label` provided, keep only PRs where any label name matches (case-insensitive).

**1.3 Classify PRs**

For each remaining PR, classify:

- **Has unresolved threads:** Query each PR for unresolved review threads (only if `resolve` is in STAGES):

  ```bash
  gh api graphql -f query='
  {
    repository(owner: "'$OWNER'", name: "'$REPO'") {
      pullRequest(number: '$PR_NUMBER') {
        reviewThreads(first: 1) {
          nodes { isResolved }
          totalCount
        }
      }
    }
  }'
  ```

  Count unresolved threads. Store as `unresolvedThreads` on the PR.

- **Review status:** From `reviewDecision` -- `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, or empty.

**1.4 Present discovery**

Use **AskUserQuestion**:

```
SWEEP DISCOVERY
---------------

  #   PR     Author          Title                               Draft  Threads  Review
  1   #42    pstaylor        Add login flow                      no     3        CHANGES_REQUESTED
  2   #45    pstaylor        Fix auth redirect                   no     0        REVIEW_REQUIRED
  3   #48    contributor     Update docs                         yes    1        --

Filters: {author: pstaylor | label: bug | none}
Pipeline: {resolve -> review -> qa}
Concurrency: {3}

Options:
1. Sweep all (Recommended)
2. Select specific items (list numbers)
3. Remove items (list numbers to exclude)
4. Abort
```

If "Select specific" or "Remove": prompt for numbers, filter list, re-confirm.

**If no items found after filtering:** Display "Nothing to sweep -- no open PRs match the filters." and exit cleanly.

**If `--dry-run`:** Display the discovery table and exit. Do not proceed to Phase 2.

---

## Phase 2: Spawn Parallel Pipelines

**2.1 Batch into waves**

Split selected PRs into batches of `CONCURRENCY_CAP`. If 8 PRs and cap=3: wave 1 (items 1-3), wave 2 (items 4-6), wave 3 (items 7-8).

**2.2 Spawn wave**

For each PR in the current wave, launch a background agent with worktree isolation.

**Important ordering:** Stages run sequentially within each pipeline in the order: `resolve` -> `review` -> `qa`. This order matters because:

- `resolve` pushes code fixes and clears threads before review
- `review` posts findings before QA validates behavior
- `qa` runs last against the most up-to-date branch state

**Agent prompt per PR:**

````
Agent:
  description: "Sweep PR #N: {title}"
  isolation: worktree
  run_in_background: true
  prompt: |
    You are running a sweep quality pipeline for PR #$PR_NUMBER in $OWNER/$REPO.

    The PR branch is: $HEAD_BRANCH (base: $BASE_BRANCH)
    PR URL: $PR_URL

    First, check out the PR branch:
    ```bash
    gh pr checkout $PR_NUMBER
    ```

    Run these stages SEQUENTIALLY. Run ALL stages to completion
    -- do NOT short-circuit on failure. Record results for each stage.

    [STAGE: resolve-threads -- INCLUDE IF "resolve" IN STAGES]
    Stage 1: Resolve Threads
    Run: Skill("pst:resolve-threads", "$PR_NUMBER")
    Parse the --- RESOLVE RESULT --- block from the output.
    Record: total conversations, processed, fixed, threads resolved.
    If the skill pushed fixes, note the new HEAD commit.

    [STAGE: code-review -- INCLUDE IF "review" IN STAGES]
    Stage 2: Code Review
    Run: Skill("pst:code-review", "$PR_NUMBER")
    This runs in standard GitHub PR mode -- posts a review to the PR.
    Record: verdict (APPROVED / CHANGES_REQUESTED / COMMENT), finding count, critical count.

    [STAGE: qa -- INCLUDE IF "qa" IN STAGES]
    Stage 3: QA
    Run: Skill("pst:qa", "$PR_NUMBER")
    This runs fully autonomously. Record the QA result.

    After ALL stages complete, output this block EXACTLY:

    --- SWEEP PIPELINE RESULT ---
    pr: #$PR_NUMBER
    title: $PR_TITLE
    author: $PR_AUTHOR
    type: pre-merge

    resolve-threads:
      status: [COMPLETED|SKIPPED|ERROR]
      total-conversations: N
      processed: N
      fixed: N
      threads-resolved: N
      pushed: [yes|no]

    code-review:
      status: [COMPLETED|SKIPPED|ERROR]
      verdict: [APPROVED|CHANGES_REQUESTED|COMMENT|--]
      findings: N
      critical: N

    qa:
      status: [COMPLETED|SKIPPED|ERROR]
      overall: [PASSED|FAILED|PARTIAL|SKIPPED]
      test-cases-total: N
      test-cases-passed: N
      test-cases-failed: N

    pipeline-overall: [PASSED|FAILED|ERROR]
    --- END SWEEP PIPELINE RESULT ---
````

Only include stages that are in `STAGES`. For omitted stages, output `status: SKIPPED` in the result block.

**2.3 Monitor wave progress**

As each background agent completes (orchestrator is notified automatically), parse the `SWEEP PIPELINE RESULT` block from its result. Display incremental progress:

```
SWEEP PROGRESS
--------------

Wave 1 of 2:

  #   PR     Author     Resolve    Review        QA         Overall
  1   #42    pstaylor   3 fixed    APPROVED      3/3 PASS   PASSED
  2   #45    pstaylor   0 threads  CHANGES (1c)  RUNNING    --
  3   #48    contrib    SKIPPED    COMMENT       2/4 FAIL   FAILED
```

After all agents in a wave complete, start the next wave.

**2.4 Handle agent failures**

If an agent crashes or returns without a valid `SWEEP PIPELINE RESULT` block:

- Record the item as `ERROR` with the agent's error output
- Continue with remaining items
- Include in triage report

---

## Phase 3: Triage Report

**3.1 Generate report**

Create a markdown report at `/tmp/pst-sweep-$(date +%Y%m%d-%H%M%S).md`:

```markdown
# Sweep Report -- [date]

## Summary

| Metric    | Count |
| --------- | ----- |
| Total PRs | N     |
| Passed    | N     |
| Failed    | N     |
| Errors    | N     |

Filters: {author: X | label: Y | none}
Stages: {resolve, review, qa}

## Results

### PR #42 -- Add login flow (pstaylor) -- PASSED

**Resolve Threads:** 3 conversations processed, 3 fixed, pushed
**Code Review:** APPROVED -- 0 findings
**QA:** 3/3 test cases passed

---

### PR #48 -- Update docs (contributor) -- FAILED

**Resolve Threads:** SKIPPED (--no-drafts excluded, or not in stages)
**Code Review:** COMMENT -- 2 findings (0 critical)
**QA:** 2/4 test cases passed -- 2 FAILED

- TC-2: Broken link in sidebar -- FAIL
- TC-4: Image alt text missing -- FAIL

---

[...per-PR sections...]
```

**3.2 Interactive triage (only if failures exist)**

If ALL items passed -> skip triage, display "All clear" summary, jump to Phase 4.

For each failed/errored PR, present options via **AskUserQuestion**:

**For failed PRs:**

```
PR #48 -- Update docs (contributor) -- FAILED

Resolve: -- | Review: 2 findings | QA: 2/4 failed

Options:
1. Fix now -- spawn an agent to address findings and push
2. Post summary comment on PR
3. View full details
4. Skip -- acknowledge and move on
```

Option behaviors:

- **Fix now** -- launch an Agent with `isolation: worktree`:

  ````
  Agent:
    description: "Fix sweep findings for PR #N"
    isolation: worktree
    prompt: |
      Address these findings from the sweep pipeline for PR #$PR_NUMBER:

      Code Review Findings:
      [list findings]

      QA Failures:
      [list QA failures]

      Check out the PR branch, fix each issue, commit changes, and push.
      ```bash
      gh pr checkout $PR_NUMBER
      ```
  ````

- **Post comment** -- post a summary of all pipeline findings as a PR comment:

  ```bash
  gh pr comment $PR_NUMBER --body "$(cat <<'EOF'
  ## Sweep Results

  **Pipeline: FAILED**

  [stage summaries]
  EOF
  )"
  ```

- **View details** -- display the full section from the sweep report
- **Skip** -- record decision and move on

**For errored items:**

```
PR #50 -- Feature X -- ERROR

Agent crashed: [error excerpt]

Options:
1. Retry pipeline
2. Skip
```

If "Retry": re-launch the agent for that item.

**3.3 Clean up report**

```bash
rm -f "$REPORT_PATH"
```

---

## Phase 4: Summary

```
--- SWEEP RESULT ---
timestamp: [ISO 8601]
filters: {author: X, label: Y | none}
stages: {resolve, review, qa}
items-total: N
items-passed: N
items-failed: N
items-errored: N

results:
  - pr: #42
    author: pstaylor
    pipeline: PASSED
    resolve: 3 fixed
    review: APPROVED
    qa: 3/3

  - pr: #45
    author: pstaylor
    pipeline: PASSED
    resolve: 0 threads
    review: APPROVED
    qa: 5/5

  - pr: #48
    author: contributor
    pipeline: FAILED
    resolve: SKIPPED
    review: COMMENT (2 findings)
    qa: 2/4
    triage: fix-now

--- END SWEEP RESULT ---
```

---

## Edge Cases

| Scenario                       | Action                                                                 |
| ------------------------------ | ---------------------------------------------------------------------- |
| No open PRs                    | "Nothing to sweep" message, exit cleanly                               |
| All PRs pass                   | Skip triage walk-through, "All clear" summary                          |
| Agent crash                    | Record ERROR, continue other agents, include in triage                 |
| `gh` not authenticated         | Abort with: "Run `gh auth login` first"                                |
| Concurrency cap exceeded       | Batch into waves (Phase 2.1)                                           |
| User cancels mid-triage        | Partial results, still emit SWEEP RESULT                               |
| PR has no review threads       | `resolve` stage completes instantly with "No unresolved conversations" |
| PR branch is stale             | Pipeline runs anyway; code-review may flag staleness                   |
| Rate limiting (429)            | Wait and retry once per affected API call                              |
| Worktree creation fails        | Record ERROR for that item, continue others                            |
| `--author` matches no PRs      | "No open PRs match --author X" and exit cleanly                        |
| `--label` matches no PRs       | "No open PRs match --label X" and exit cleanly                         |
| Combined filters match nothing | "No open PRs match the given filters" and exit cleanly                 |

## Error Handling

Graceful degradation throughout -- never abort the entire sweep for a single item failure.

- **Per-item isolation:** Each pipeline runs in its own worktree. A failure in one does not affect others.
- **Stage completion:** All stages in a pipeline run to completion, even if earlier stages fail. This ensures the triage report has maximum information.
- **Agent recovery:** If an agent crashes, the error is captured and included in the triage report. The user can retry individual items.

## Important Guidelines

- **User owns all actions:** Sweep discovers and reports. Triage actions require confirmation.
- **No auto-merge:** Sweep never merges PRs.
- **Standard code-review mode:** Sweep uses standard GitHub-mode code-review, NOT `--preflight` or `--sweep`. Those are for pre-push author flow.
- **Resolve-threads runs first:** This ensures code fixes are pushed and threads are cleared before code-review and QA run against the updated branch.
- **Worktree cleanup:** Worktrees created by the Agent tool are automatically cleaned up if no changes are made. Fix-now worktrees persist for the user to review.
- **Concurrency awareness:** Respect the cap to avoid overwhelming CI, API rate limits, and local resources.
