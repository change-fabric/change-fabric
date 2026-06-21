---
name: pst:sweep
description: Parallel quality sweep across open PRs -- tournament scouting picks the best pipeline strategy before executing for real
argument-hint: "[--author <login>] [--label <name>] [--cap N] [--dry-run] [--stages resolve,review,qa] [--no-drafts]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, AskUserQuestion, Skill
---

# Sweep -- Tournament-Scouted Quality Pipelines Across Open PRs

Discovers open PRs, runs a best-of-3 dry-run tournament to select the optimal pipeline
strategy, then executes the winner for real across all PRs in isolated worktrees.

---

## Arguments

<arguments> #$ARGUMENTS </arguments>

- `--author <login>` -- only sweep PRs by this GitHub user (case-insensitive)
- `--label <name>` -- only sweep PRs with this label
- `--cap N` -- concurrency cap (default 3, max 10)
- `--dry-run` -- discover and classify PRs but do not run pipelines
- `--stages <list>` -- comma-separated subset of `resolve`, `review`, `qa` (default: all three)
- `--no-drafts` -- exclude draft PRs (default: drafts included)

Multiple filters combine as AND. No arguments sweeps all open PRs.

---

## Phase 0: Guards & Config

```bash
OWNER_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
OWNER=$(echo "$OWNER_REPO" | cut -d/ -f1)
REPO=$(echo "$OWNER_REPO" | cut -d/ -f2)
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
```

Stop if `gh` is unavailable or `gh auth status` fails.

Parse: `CONCURRENCY_CAP` (default 3), `STAGES` (default `resolve,review,qa`), `AUTHOR_FILTER`,
`LABEL_FILTER`, `INCLUDE_DRAFTS`, `DRY_RUN`. Validate cap is 1-10 and stages are a valid subset.

---

## Phase 1: PR Discovery

**Fetch:**

```bash
gh pr list --state open \
  --json number,title,headRefName,baseRefName,url,isDraft,author,labels,reviewDecision \
  --limit 100
```

**Filter:** Apply `--no-drafts`, `--author`, `--label` as AND. If nothing remains: print
"Nothing to sweep -- no open PRs match the filters." and exit cleanly.

**Classify:** For each PR, if `resolve` is in STAGES query unresolved thread count via GraphQL
`reviewThreads`. Store `unresolvedThreads` and `reviewDecision`.

**Confirm (AskUserQuestion):**

```
SWEEP DISCOVERY
---------------
  #   PR    Author     Title                  Draft  Threads  Review
  1  #42  pstaylor  Add login flow              no      3    CHANGES_REQUESTED
  2  #45  pstaylor  Fix auth redirect            no      0    REVIEW_REQUIRED

Filters: {author/label/none}  Stages: {resolve -> review -> qa}

1. Sweep all (Recommended)
2. Select specific items
3. Remove items
4. Abort
```

If `--dry-run`: display table and exit. If no items after selection: exit cleanly.

---

## Tournament Gate

**Skip condition (1-2 PRs):** Skip tournament, set `WINNING_STRATEGY=B`, jump to Phase 2.

Otherwise, ask (AskUserQuestion):

> Scout with N=3 strategies before executing? (Yes / Execute Standard / Skip sweep)

- **Yes:** run Phase T.
- **Execute Standard:** set `WINNING_STRATEGY=B`, skip Phase T.
- **Skip sweep:** exit cleanly.

---

## Phase T: Dry-Run Scout Tournament

Spawn **3 foreground Sonnet agents** in a single response turn (NO `run_in_background`).
All three must complete before the judge. Each reads PR state via `gh pr view --json` and
`gh pr checks` only -- NO mutations, NO comment posts, NO pushes.

**Inject the Phase 1 PR list** (`{number, title, isDraft, unresolvedThreadCount,
reviewDecision, checkStatus}`) into each scout prompt as the single source of truth.
Scouts must not run `gh pr list`. Each scout prompt must open with: "You have access to
Bash (read-only: `gh api`, `gh pr view`, `git log`, `git diff`) and Read only. Do not
use Edit, Write, or invoke any Skill tool."

### Strategy A -- Conservative

Query `gh pr view $PR_NUMBER --json reviewThreads` per PR to count unresolved bot threads
that WOULD be resolved. Skip code-review and qa. Report fixable threads, merge conflicts,
and top cleanup candidates. No sub-skill calls.

### Strategy B -- Standard

Read `gh pr checks $PR_NUMBER` and the injected `unresolvedThreadCount` / `reviewDecision`
per PR. Estimate projected findings per stage across all PRs. Skip drafts and
conflict-blocked PRs. No sub-skill calls.

### Strategy C -- Review-gated

Use `reviewDecision` from the injected PR list. Gate qa estimates on
`reviewDecision == "APPROVED"`; skip qa for `CHANGES_REQUESTED` PRs. Report which PRs
gate out and why. No sub-skill calls.

### Required result block (each agent)

```
---sweep-result---
STRATEGY: <A|B|C>
PRs_TOTAL: <integer: total PRs in batch>
PRs_PROCESSABLE: <integer>
PRs_BLOCKED: <integer>
PRs_ESTIMATED_IMPROVED: <integer: PRs this strategy would move forward>
ESTIMATED_SIGNAL_FINDINGS: <integer: threads/checks that are real issues>
ESTIMATED_NOISE_FINDINGS: <integer: bot noise, auto-closeable items>
ESTIMATED_MUTATIONS: <integer: comment posts + pushes this strategy would make>
FINDINGS_SUMMARY: <one-line summary>
---end-sweep-result---
```

---

## Phase T.2: Opus Judge

Parse all three `---sweep-result---` blocks. Spawn one **foreground Opus agent**
(`model: opus`; blocks until done). Prompt:

> Score each strategy (1-5 per axis):
>
> - **Coverage**: `PRs_ESTIMATED_IMPROVED / PRs_TOTAL` -- how many PRs move forward?
> - **Precision**: `ESTIMATED_SIGNAL_FINDINGS / (SIGNAL + NOISE)` -- real issues vs noise;
>   review-gated strategies score higher for blocking qa on CHANGES_REQUESTED PRs.
> - **Efficiency**: `ESTIMATED_MUTATIONS / PRs_ESTIMATED_IMPROVED` -- mutations per PR
>   improved (fewer is better).
>
> Return JSON only:
>
> ```json
> {
>   "winner": "A|B|C",
>   "scores": {
>     "A": { "coverage": 0, "precision": 0, "efficiency": 0 },
>     "B": { "coverage": 0, "precision": 0, "efficiency": 0 },
>     "C": { "coverage": 0, "precision": 0, "efficiency": 0 }
>   },
>   "reasoning": "one sentence"
> }
> ```

Set `WINNING_STRATEGY` from `winner`. Log scores and reasoning before proceeding.

---

## Phase 2: Execute Winning Strategy

Announce the winning strategy and Opus reasoning. Run the real (non-dry-run) sweep.

**2.1 Batch into waves:** Split selected PRs into groups of `CONCURRENCY_CAP`. Start
wave 2 only after wave 1 completes.

**2.2 Pipeline per strategy:**

- **Strategy A:** one background agent per PR running `pst:resolve-threads` only.
- **Strategy B:** one background agent per PR running resolve -> code-review -> qa (skip
  drafts and conflict-blocked PRs).
- **Strategy C:** one background agent per PR running code-review first. After
  code-review, run `gh pr view $PR_NUMBER --json reviewDecision`; skip qa if
  `reviewDecision != "APPROVED"`.

Each agent uses `isolation: worktree`. Bootstrap before running stages:

```bash
gh pr checkout $PR_NUMBER
if [ ! -f package.json ]; then
  echo "No package.json -- skipping JS bootstrap and JS quality gates."
  PKG=""
elif [ -f pnpm-lock.yaml ]; then PKG="pnpm"
elif [ -f yarn.lock ]; then PKG="yarn"
else PKG="npm"; fi
if [ -n "$PKG" ]; then
  if grep -q '"worktree:init"' package.json 2>/dev/null
  then $PKG run worktree:init
  else $PKG install --frozen-lockfile; fi
fi
```

Gate all `$PKG run ...` commands on `[ -n "$PKG" ]`.

Required result block per PR agent:

```
--- SWEEP PIPELINE RESULT ---
pr: #$PR_NUMBER
title: $PR_TITLE
resolve-threads: status: [COMPLETED|SKIPPED|ERROR] | fixed: N | pushed: [yes|no]
code-review: status: [COMPLETED|SKIPPED|ERROR] | verdict: [APPROVED|CHANGES_REQUESTED|COMMENT|--] | findings: N
qa: status: [COMPLETED|SKIPPED|ERROR] | overall: [PASSED|FAILED|PARTIAL|SKIPPED]
pipeline-overall: [PASSED|FAILED|ERROR]
--- END SWEEP PIPELINE RESULT ---
```

Run ALL stages to completion -- do NOT short-circuit on failure.

**2.3 Progress display** as agents complete:

```
SWEEP PROGRESS (Strategy B -- Standard)
  #  PR    Resolve       Review          QA          Overall
  1  #42   3 fixed       APPROVED        3/3 PASS    PASSED
  2  #45   RUNNING       --              --           --
```

**2.4 Agent failures:** Record as ERROR, continue remaining agents, include in triage.

---

## Phase 3: Triage Report

Write `/tmp/pst-sweep-$(date +%Y%m%d-%H%M%S).md`. If all passed: "All clear", jump to
Phase 4.

For each failed/errored PR (AskUserQuestion per item):

```
PR #48 -- FAILED | Review: 2 findings | QA: 2/4 failed

1. Fix now (spawn worktree agent to address findings and push)
2. Post summary comment on PR
3. View full details
4. Skip
```

- **Fix now:** Agent with `isolation: worktree`, `gh pr checkout`, address findings, push.
- **Post comment:** `gh pr comment $PR_NUMBER --body "..."` with stage summaries.
- **Retry** (error items): re-launch agent for that PR.

Clean up: `rm -f "$REPORT_PATH"`.

---

## Phase 4: Summary

```
--- SWEEP RESULT ---
timestamp: [ISO 8601]
strategy: [A|B|C] ([Conservative|Standard|Review-gated])
items-total: N | items-passed: N | items-failed: N | items-errored: N

results:
  - pr: #42 | pipeline: PASSED | resolve: 3 fixed | review: APPROVED | qa: 3/3
  - pr: #45 | pipeline: FAILED | resolve: 0 | review: COMMENT (2) | qa: 2/4
--- END SWEEP RESULT ---
```

---

## Edge Cases & Guidelines

| Scenario                | Action                                           |
| ----------------------- | ------------------------------------------------ |
| No open PRs             | Exit: "Nothing to sweep"                         |
| All PRs pass            | Skip triage walk-through, "All clear"            |
| Agent crash             | Record ERROR, continue others, include in triage |
| `gh` not authenticated  | Abort: "Run `gh auth login` first"               |
| Cap exceeded            | Batch into waves                                 |
| 1-2 PRs                 | Skip tournament, execute Standard                |
| Rate limiting (429)     | Wait and retry once per affected call            |
| Worktree creation fails | Record ERROR, continue others                    |
| User cancels mid-triage | Partial results, still emit SWEEP RESULT         |

- **User owns all actions:** Triage actions require confirmation. No auto-merge.
- **Dry-run scouts read only:** `gh pr view --json` and `gh pr checks` -- no mutations.
- **Stage ordering (B/C):** resolve -> review -> qa. All stages run to completion.
- **Standard code-review mode:** GitHub PR mode, NOT `--preflight` or `--sweep`.
- **Worktree cleanup:** Auto-cleaned if no changes. Fix-now worktrees persist for user review.
- **Concurrency awareness:** Respect the cap to avoid overwhelming CI and API rate limits.
