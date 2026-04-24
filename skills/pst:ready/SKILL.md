---
name: pst:ready
description: Bring one or many open PRs to merge-ready state -- rebase onto base, await CI and auto-fix failures, loop resolve-threads + code-review until clean, re-verify CI, open in the browser. Multiple PR URLs run in parallel via background agents in isolated worktrees, cross-repo capable.
argument-hint: "<PR-URL> [<PR-URL>...] [--dry-run] [--no-open] [--open-all] [--max-parallel N] [--max-ci-attempts N] [--max-review-rounds N]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, AskUserQuestion, Skill
---

# Bring PRs to Merge-Ready

Take one or more open GitHub pull requests from wherever they are today (behind base, failing CI, unresolved threads, outstanding CHANGES_REQUESTED reviews) and drive each to a merge-ready state without further user interaction.

For a **single PR**, run the full pipeline in place (or in a worktree/temp clone for cross-repo). For **multiple PRs**, dispatch each to its own background agent running the same pipeline in an isolated worktree, group PRs by repo to share temp clones where sensible, then aggregate the results at the end.

The per-PR pipeline is pure composition over existing `/pst:*` skills plus three pieces of new logic: a bounded CI wait + auto-fix loop, a post-green PR title/description refresh, and an auto-validation pass over the test-plan checkboxes. It chains them in the order a human would:

1. Rebase onto the PR's base branch (`pst:rebase`).
2. Wait for CI; when something fails, diagnose and patch until green (new logic here).
3. Address every unresolved review thread (`pst:resolve-threads`).
4. Run a verified-fix code review to catch new issues (`pst:code-review --sweep`).
5. Repeat (3) + (4) until no unresolved threads and no remaining criticals.
6. Re-verify CI is still green after all review-loop commits.
7. Refresh the PR title and description to describe what actually shipped.
8. Parse the test plan, auto-validate the items that can be validated, post a validation comment, and tick the boxes that passed.
9. Open the PR in the browser so the human can merge.

---

## Input

<arguments> #$ARGUMENTS </arguments>

**Parse arguments:**

- `<PR-URL>` (required, one or more) -- full GitHub PR URLs, e.g. `https://github.com/owner/repo/pull/42`. Bare PR numbers are rejected; URLs are always required so cross-repo is unambiguous. Multiple URLs trigger dispatcher mode (see below).
- `--dry-run` -- report what would happen at every phase; no pushes, no thread resolutions, no rebase writes, no browser open. Flows through to every child agent in dispatcher mode.
- `--no-open` -- skip browser pop(s) at the end. In dispatcher mode, suppresses opening any PR.
- `--open-all` -- dispatcher mode only: also open BLOCKED PRs (default opens only READY). Ignored in single-PR mode.
- `--max-parallel N` -- dispatcher mode only: cap concurrent background agents at N. Default `4` to avoid GitHub API throttling. Ignored with 1 URL.
- `--max-ci-attempts N` -- override the default CI auto-fix attempt budget (default `3`). Flows through to every child.
- `--max-review-rounds N` -- override the default review-loop round cap (default `5`). Flows through to every child.

**Validate:**

| Condition                                         | Action                                                         |
| ------------------------------------------------- | -------------------------------------------------------------- |
| No PR URL provided                                | Stop with usage: `/pst:ready <PR-URL> [<PR-URL>...] [flags]`   |
| Any URL fails `https://github.com/.+/.+/pull/\d+` | Stop with the first offender: "Provide a full GitHub PR URL."  |
| Duplicate URLs in the list                        | De-duplicate silently; log `NOTE: deduped N duplicate URL(s)`. |
| `gh` not available                                | Stop: "GitHub CLI (gh) is required."                           |
| `git` not available                               | Stop: "git is required."                                       |

---

## Dispatch Router

The router runs **before** Phase 0. It chooses between:

- **Single-PR mode** -- exactly 1 URL → execute Phases 0..8 inline, as described below. This is the original pipeline; no behavior change for 1-URL invocations.
- **Dispatcher mode** -- 2+ URLs → jump to **Phase D** (dispatcher) and skip Phases 0..8 at the top level. Each background child agent runs Phases 0..8 for its assigned PR.

---

## Phase D -- Dispatcher (multi-PR mode)

**Runs only when 2+ URLs are provided.** The dispatcher does no pipeline work itself -- it plans, launches, and aggregates.

### D.1 Fetch metadata for every URL

For each URL in parallel (`gh pr view` calls are independent), collect:

```bash
gh pr view "$URL" --json number,url,title,state,isDraft,headRefName,headRefOid,baseRefName,mergeable
```

If any URL returns `state != OPEN`, record it and continue; that PR will be reported as `SKIPPED (closed|merged|draft)` in the final matrix but does not block the other PRs.

### D.2 Group by repository

Extract `owner/repo` from each URL. Bucket PRs into groups:

- **Group A -- cwd-repo group:** PRs whose `owner/repo` matches the current working directory's repo (via `gh repo view --json nameWithOwner --jq .nameWithOwner`). Zero or one group of this kind. These children use worktrees inside the current repo: `$REPO_ROOT/.worktrees/ready-PR-<N>`.
- **Group B..Z -- foreign-repo groups:** One group per distinct `owner/repo` not matching cwd. For each such group, the dispatcher creates **one** temp clone shared across all PRs in that group:

  ```bash
  TMPDIR="${TMPDIR:-${TEMP:-/tmp}}"
  CLONE_DIR=$(mktemp -d "$TMPDIR/pst-ready-<owner>-<repo>-XXXXXX")
  gh repo clone "<owner>/<repo>" "$CLONE_DIR" -- --depth=200
  ```

  Children inside this group use worktrees inside `$CLONE_DIR`: `$CLONE_DIR/.worktrees/ready-PR-<N>`.

  Depth 200 (vs. 50 used by the single-PR cross-repo path) because multiple PRs in the same repo are more likely to collectively reach further back in history; `gh pr checkout` will deepen on demand anyway.

Log the grouping summary:

```
Dispatching 5 PRs across 3 repo(s):
  cwd (owner-a/repo-x):  #42, #51
  temp clone owner-b/repo-y:  #7, #9
  temp clone owner-c/repo-z:  #33
```

### D.3 Write dispatcher progress

At the top of the caller's cwd, write `.pst-ready-dispatcher.json` (excluded from git the same way child progress files are):

```json
{
  "started_at": "<iso8601>",
  "urls": ["https://.../pull/42", "..."],
  "flags": {
    "dry_run": false,
    "open_all": false,
    "max_parallel": 4,
    "max_ci_attempts": 3,
    "max_review_rounds": 5
  },
  "groups": [
    {
      "owner_repo": "owner-a/repo-x",
      "clone_dir": null,
      "cwd_group": true,
      "prs": [42, 51]
    },
    {
      "owner_repo": "owner-b/repo-y",
      "clone_dir": "/tmp/pst-ready-owner-b-repo-y-abc123",
      "cwd_group": false,
      "prs": [7, 9]
    }
  ],
  "children": []
}
```

### D.4 Prepare child worktrees

For each PR assigned to a group, the dispatcher pre-creates its worktree before spawning the child agent, so each child agent receives a ready-to-use path:

```bash
# Inside each group's repo root ($REPO_ROOT for cwd group, $CLONE_DIR for foreign groups)
git fetch origin pull/$N/head:refs/pst-ready/pr-$N 2>/dev/null \
  || gh pr checkout "$N" -b "pst-ready-pr-$N"  # fallback if raw fetch fails

WORKTREE_PATH="<group-root>/.worktrees/ready-PR-$N"
git worktree remove --force "$WORKTREE_PATH" 2>/dev/null
git worktree add "$WORKTREE_PATH" "refs/pst-ready/pr-$N"
```

Rationale: the dispatcher does worktree creation, not the child, so that the child agent's `isolation: "worktree"` budget is preserved for its own scratch work (sub-agents inside the child Phase 3 still get their own isolated worktrees for CI fixes).

### D.5 Launch background agents

Respecting `--max-parallel N` (default 4), spawn children in batches. For each child:

```
Agent({
  description: "pst:ready PR #<N> (<owner>/<repo>)",
  subagent_type: "general-purpose",
  run_in_background: true,
  prompt: "<see child prompt template below>"
})
```

If the number of PRs exceeds `--max-parallel`, queue the overflow and launch replacements as earlier children complete (you will be notified of completion per Agent-tool semantics).

**Child prompt template:**

```
You are a focused sub-agent running the per-PR pipeline of /pst:ready for ONE pull request.

Assigned PR:        {PR_URL}
Working directory:  {WORKTREE_PATH}  (already created, on the PR head, clean tree)
Base branch:        {BASE_BRANCH}
Head SHA:           {HEAD_SHA}
Group root:         {GROUP_ROOT}  (shared with sibling PRs in the same repo -- treat as read-only from other siblings' perspective)
Flags to honor:     --max-ci-attempts={N} --max-review-rounds={M} {--dry-run?}

Your job is to execute Phases 0..8 from the /pst:ready single-PR pipeline entirely inside {WORKTREE_PATH}. DO NOT open the browser -- the dispatcher handles that after it collects all children. DO NOT write to the dispatcher's progress file.

Write your own progress file at:
  {WORKTREE_PATH}/.pst-ready-progress.json
so a dispatcher resume can see per-PR state.

When you are done, return a single JSON object on the final line of your output in this exact shape:

  PST_READY_CHILD_RESULT={
    "pr_url": "{PR_URL}",
    "pr_number": <N>,
    "status": "READY" | "BLOCKED" | "SKIPPED",
    "rebase": "success" | "skipped-up-to-date" | "conflict",
    "ci_pass1_attempts": <int>,
    "review_rounds": <int>,
    "ci_pass2_attempts": <int>,
    "pr_refresh": "updated" | "unchanged" | "skipped" | "failed",
    "test_plan": { "validated": <int>, "failed": <int>, "manual": <int> },
    "residual": [ ... phase-scoped residual entries ... ],
    "final_head_sha": "<sha>",
    "notes": "optional short string"
  }

Do not emit long progress narration -- keep the response concise. Follow the
/pst:ready single-PR Phases 0..8 exactly as documented.
```

### D.6 Collect and aggregate

As children complete, parse each child's `PST_READY_CHILD_RESULT={...}` line and append to `children` in the dispatcher progress file.

Once all children have reported, classify:

- `READY`: `status == "READY"` and `residual` is empty.
- `BLOCKED`: `status == "BLOCKED"` -- child halted with residual findings or unfixable CI.
- `SKIPPED`: `status == "SKIPPED"` -- PR was closed/merged/draft.
- `ERROR`: child agent itself crashed (no parsable `PST_READY_CHILD_RESULT` line) -- record the last 20 lines of its output for the matrix.

### D.7 Open browsers (respect flags)

Unless `--no-open`:

- Default: open only `READY` PRs: `for url in ${ready_urls[@]}; do gh pr view "$url" --web; done`
- `--open-all`: open `READY` and `BLOCKED` PRs (skip `SKIPPED` and `ERROR`).

### D.8 Print final matrix

```
/pst:ready dispatch complete: <N> PRs across <M> repo(s)

  owner-a/repo-x  #42  READY     rebased ✓  CI 1 attempt ✓  reviews clean ✓  CI 1 attempt ✓  opened
  owner-a/repo-x  #51  BLOCKED   rebased ✓  CI 3 attempts → residual typecheck in apps/web/src/auth.ts
  owner-b/repo-y  #7   READY     rebased (up-to-date)  CI 1 attempt ✓  reviews clean ✓  opened
  owner-b/repo-y  #9   SKIPPED   PR is MERGED; nothing to ready.
  owner-c/repo-z  #33  ERROR     child agent crashed -- see /tmp/pst-ready-children/PR-33.log

Temp clones preserved for resume:
  /tmp/pst-ready-owner-b-repo-y-abc123
  /tmp/pst-ready-owner-c-repo-z-def456
```

### D.9 Cleanup vs. resume

- On full success (all `READY` or `SKIPPED`): delete `.pst-ready-dispatcher.json` and the temp clones.
- On any `BLOCKED` / `ERROR`: preserve both. A subsequent `/pst:ready` invocation with the same URL set reads `.pst-ready-dispatcher.json`, reuses the group clones and worktrees, and only re-dispatches children whose `status != "READY"`.

### D.10 Dry-run in dispatcher mode

`--dry-run` at the dispatcher level:

- Skip cloning foreign repos; use `gh pr view`-only analysis.
- Skip creating worktrees.
- Report the planned group/assignment matrix and exit. Do not spawn child agents.

---

## Per-PR Pipeline (Phases 0-8)

The phases below run either inline (single-PR mode) or inside each dispatched child agent (multi-PR mode). Their behavior is identical in both cases.

---

## Phase 0 -- Intake & Guards

Extract metadata and confirm the PR is actionable.

```bash
PR_URL="$1"
PR_JSON=$(gh pr view "$PR_URL" --json number,url,title,state,isDraft,headRefName,headRefOid,baseRefName,headRepository,repository,mergeable)
PR_NUMBER=$(echo "$PR_JSON" | jq -r .number)
PR_STATE=$(echo "$PR_JSON"  | jq -r .state)
IS_DRAFT=$(echo "$PR_JSON"  | jq -r .isDraft)
HEAD_BRANCH=$(echo "$PR_JSON" | jq -r .headRefName)
HEAD_SHA=$(echo "$PR_JSON"    | jq -r .headRefOid)
BASE_BRANCH=$(echo "$PR_JSON" | jq -r .baseRefName)
PR_OWNER_REPO=$(echo "$PR_URL" | sed -E 's|https://github.com/([^/]+/[^/]+)/pull/.*|\1|')
PR_OWNER=$(echo "$PR_OWNER_REPO" | cut -d/ -f1)
PR_REPO=$(echo  "$PR_OWNER_REPO" | cut -d/ -f2)
```

**Stop conditions:**

| Condition                                            | Action                                                          |
| ---------------------------------------------------- | --------------------------------------------------------------- |
| `PR_STATE` is not `OPEN`                             | Stop: "PR #$PR_NUMBER is $PR_STATE; nothing to ready."          |
| `IS_DRAFT` is `true`                                 | Ask the user (AskUserQuestion) whether to proceed; if no, stop. |
| `mergeable` is `CONFLICTING` and `--dry-run` not set | Proceed -- the rebase phase will surface the conflict.          |

(Recovery-from-progress-file logic is deferred to the end of Phase 1, once `$WORK_DIR` is resolved -- see Phase 1 step 7.)

---

## Phase 1 -- Workspace Setup (cross-repo capable)

Pattern mirrors `pst:code-review` workspace setup. The objective is to have a clean working tree on the PR's head commit before we do anything else.

1. **Resolve cwd repo identity:**

   ```bash
   CWD_OWNER_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "")
   ```

2. **Cross-repo branch:** If `CWD_OWNER_REPO != PR_OWNER_REPO`:

   ```bash
   TMPDIR="${TMPDIR:-${TEMP:-/tmp}}"
   WORK_DIR=$(mktemp -d "$TMPDIR/pst-ready-XXXXXX")
   gh repo clone "$PR_OWNER_REPO" "$WORK_DIR" -- --depth=50
   cd "$WORK_DIR"
   gh pr checkout "$PR_NUMBER"
   ```

   Record `WORK_DIR` and `cross_repo=true` in the progress file so resume lands in the same place.

3. **Same-repo branch, clean cwd on PR head:** If current branch matches `$HEAD_BRANCH`, `HEAD` matches `$HEAD_SHA`, and `git status --porcelain` is empty -- work in place. Set `WORK_DIR=$(pwd)`.

4. **Same-repo, different branch or dirty tree:** Create a detached worktree:

   ```bash
   REPO_ROOT=$(git rev-parse --path-format=absolute --git-common-dir | sed 's|/.git$||')
   git fetch origin "$HEAD_BRANCH"
   WORK_DIR="$REPO_ROOT/.worktrees/ready-PR-$PR_NUMBER"
   git worktree remove --force "$WORK_DIR" 2>/dev/null
   git worktree add "$WORK_DIR" "$HEAD_BRANCH"
   cd "$WORK_DIR"
   ```

   (Non-detached here because `pst:rebase` needs a branch to push back to.)

5. **Exclude progress file from git:**

   ```bash
   grep -qxF '.pst-ready-progress.json' .git/info/exclude 2>/dev/null \
     || echo '.pst-ready-progress.json' >> .git/info/exclude
   ```

6. **Write initial progress:**

   ```json
   {
     "pr_url": "...",
     "pr_number": 42,
     "head_branch": "feature/x",
     "base_branch": "main",
     "work_dir": "/abs/path",
     "cross_repo": false,
     "state": "rebase",
     "completed": ["intake", "workspace"],
     "ci_attempts_pass1": 0,
     "ci_attempts_pass2": 0,
     "review_rounds": 0,
     "residual": []
   }
   ```

7. **Recovery from a prior run:** Now that `$WORK_DIR` is known, look for an existing progress file at `$WORK_DIR/.pst-ready-progress.json` from a previous invocation. If one exists AND its `pr_url` matches AND its `updated_at` is within the last 24 hours, read its `completed` list and resume from the first phase **not** in that list. Do not re-run Phase 2 if `"rebase"` is already completed, etc. If the file is missing, stale, or for a different PR, overwrite with the fresh progress from step 6.

From this phase forward, **all commands run in `$WORK_DIR`**.

---

## Phase 2 -- Rebase

Delegate entirely to `pst:rebase`, passing the PR base branch explicitly so it does not re-infer:

```
Skill("pst:rebase", "$BASE_BRANCH${DRY_RUN:+ --dry-run}")
```

After the skill returns:

- **Success path:** `pst:rebase` force-pushed with `--force-with-lease`. Capture the new `HEAD_SHA`:
  ```bash
  git fetch origin "$HEAD_BRANCH"
  HEAD_SHA=$(git rev-parse "origin/$HEAD_BRANCH")
  ```
- **Conflict path:** `pst:rebase` will have stopped with conflict output. Surface its output verbatim and halt `pst:ready`. Record `residual: [{phase: "rebase", reason: "unresolved-conflicts"}]` in progress so the user can resume after manual resolution.
- **`--dry-run`:** `pst:rebase` prints the analysis. Continue to Phase 3 in read-only mode.

Mark `rebase` completed.

---

## Phase 3 -- CI Wait + Auto-Fix (Pass 1)

This is the only piece of genuinely new logic. It runs up to `MAX_CI_ATTEMPTS` times.

### 3.1 Wait for CI to settle

```bash
gh pr checks "$PR_NUMBER" --watch --interval 20
```

`--watch` blocks until every required check reaches a terminal state (success/failure/cancelled/skipped). `--interval 20` keeps the poll rate friendly.

### 3.2 Read results

```bash
CHECKS_JSON=$(gh pr checks "$PR_NUMBER" --json name,state,link,bucket,workflow)
```

Categorize by `bucket`:

- `pass` / `skipping` -- ignore.
- `fail` / `cancel` -- collect for fix attempts.
- `pending` -- shouldn't exist after `--watch`; if seen, re-enter 3.1.

**If zero `fail`/`cancel` checks -> Phase 4.**

### 3.3 Diagnose failures

For each failing check:

```bash
RUN_ID=$(gh run list --branch "$HEAD_BRANCH" --limit 20 \
  --json databaseId,name,conclusion,headSha,workflowName \
  --jq ".[] | select(.headSha == \"$HEAD_SHA\" and .workflowName == \"$WORKFLOW\") | .databaseId" \
  | head -1)
LOGS=$(gh run view "$RUN_ID" --log-failed 2>/dev/null | tail -500)
```

Classify from `$LOGS`:

| Signal                                                       | Classification |
| ------------------------------------------------------------ | -------------- |
| `error TS\d+:`, `tsc`, `type`                                | `typecheck`    |
| `ESLint`, `eslint`, `Lint`                                   | `lint`         |
| `FAIL `, `Test Failed`, `vitest`, `jest`                     | `test`         |
| `webpack`, `next build`, `Build failed`, `ENOENT`            | `build`        |
| `429`, `504`, `ECONNRESET`, `Network`, `timeout waiting for` | `infra-flake`  |
| Nothing recognizable                                         | `unknown`      |

### 3.4 Handle each failure

- **`infra-flake` on attempt 1:** `gh run rerun $RUN_ID --failed`. Restart from 3.1 without incrementing the attempt counter. Log a note in progress. Second flake on the same workflow -> treat as real failure.

- **`typecheck` / `lint` / `test` / `build` / `unknown`:** Delegate to a sub-agent in an isolated worktree so the fix is reproduced locally before we push.

  ```
  Agent({
    description: "Auto-fix CI failure: {check name}",
    subagent_type: "general-purpose",
    isolation: "worktree",
    prompt: """
      A CI check named "{check name}" is failing on PR #{PR_NUMBER} at commit {HEAD_SHA}.
      Classification: {typecheck|lint|test|build|unknown}.

      Failed-job log excerpt (last 500 lines):
      <<<
      {LOGS}
      >>>

      Task:
        1. Reproduce the failure locally in this worktree. Use the package manager and
           scripts detected in package.json / pyproject.toml / etc.
        2. Fix it minimally -- no drive-by refactors, no unrelated changes.
        3. Re-run the local equivalent of the failing check to verify the fix.
        4. Commit with message: "fix(ci): {one-line summary}"
        5. Do NOT push. Return a machine-readable report on the last line in this
           exact shape (single JSON object, no prose after it):

             CI_FIX_RESULT={
               "status": "fixed" | "no-fix",
               "worktree_path": "/abs/path/to/this/worktree",
               "commit_sha": "<sha of the fix commit, or null if status != fixed>",
               "files_changed": ["path/a.ts", "path/b.ts"],
               "verification_cmd": "pnpm run typecheck",
               "verification_exit": 0,
               "notes": "optional short string -- caveats, env-only hypothesis, etc."
             }

      If you cannot reproduce locally (e.g., environment-only), set status to "no-fix"
      and put the best-effort hypothesis in notes. Always return the JSON object.
    """
  })
  ```

  The orchestrator parses the `CI_FIX_RESULT={...}` line from the sub-agent's final
  message. It uses `worktree_path` and `commit_sha` as the source of truth -- no
  implicit variables.

  When `status == "fixed"`, pull the commit onto the real branch in `$WORK_DIR`:

  ```bash
  # worktree_path and commit_sha come from the parsed CI_FIX_RESULT JSON above
  git fetch "$worktree_path" "$commit_sha"
  git cherry-pick "$commit_sha"
  ```

  If `git fetch` from the worktree path fails (e.g., the worktree was cleaned up
  before we could reach it), fall back to requesting the sub-agent's diff inline
  and applying with `git apply`. Either way, follow with:

  ```bash
  git push --force-with-lease origin "$HEAD_BRANCH"
  HEAD_SHA=$(git rev-parse "origin/$HEAD_BRANCH")
  ```

- **If the sub-agent returns no viable fix for a given failure:** record it in `residual` and continue with the other failures. If every failure in this iteration failed to produce a fix, halt.

### 3.5 Loop

Increment `ci_attempts_pass1`. If < `MAX_CI_ATTEMPTS` and any fixes were applied, return to 3.1. If `MAX_CI_ATTEMPTS` is reached with failures still present, halt with a residual report:

```
Phase 3 stopped after {N} attempts.
Remaining failures:
  - {check name}: {classification}
    Last run: {url}
    Last attempt outcome: {no-repro | patch-applied-but-still-failing | sub-agent-gave-up}

Resume with: /pst:ready $PR_URL  (progress file preserved)
```

In `--dry-run` mode: do **not** invoke sub-agents or push. Report each failing check with its classification and continue to Phase 4 in read-only mode.

Mark `ci-wait-1` completed. Record `ci_attempts_pass1` used.

---

## Phase 4 -- Virtuous Review Loop

Up to `MAX_REVIEW_ROUNDS` iterations. Each round has three steps; the loop exits when the PR has stabilized (no unresolved threads, no remaining criticals/warnings, no new commits in the round).

```
Round N:
  A. Skill("pst:resolve-threads", "$PR_URL")
  B. Count unresolved threads afterward (GraphQL query below)
  C. Skill("pst:code-review", "--sweep")
  D. Evaluate exit condition
```

### 4.A Resolve threads

```
Skill("pst:resolve-threads", "$PR_URL${DRY_RUN:+ --dry-run}")
```

This skill already handles parallel worktree verification of reviewer suggestions, applying verified fixes, replying, resolving threads, dismissing CHANGES_REQUESTED reviews, and re-requesting review from humans. It may push one or more commits.

After it returns, re-resolve `HEAD_SHA`:

```bash
git fetch origin "$HEAD_BRANCH"
NEW_HEAD_SHA=$(git rev-parse "origin/$HEAD_BRANCH")
PUSHED_IN_A=$([ "$NEW_HEAD_SHA" != "$HEAD_SHA" ] && echo true || echo false)
HEAD_SHA="$NEW_HEAD_SHA"
```

### 4.B Count unresolved threads

```bash
UNRESOLVED=$(gh api graphql -f query='
{
  repository(owner: "'$PR_OWNER'", name: "'$PR_REPO'") {
    pullRequest(number: '$PR_NUMBER') {
      reviewThreads(first: 100) {
        nodes { isResolved isOutdated }
      }
    }
  }
}' --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false and .isOutdated == false)] | length')
```

### 4.C Code review sweep

```
Skill("pst:code-review", "--sweep${DRY_RUN:+ --dry-run}")
```

`--sweep` is already a bounded multi-round autonomous review-and-fix loop. It prints a final status and may push additional commits. Capture its exit summary -- specifically whether any verified criticals or warnings remain.

After it returns, re-resolve `HEAD_SHA` again:

```bash
git fetch origin "$HEAD_BRANCH"
NEW_HEAD_SHA=$(git rev-parse "origin/$HEAD_BRANCH")
PUSHED_IN_C=$([ "$NEW_HEAD_SHA" != "$HEAD_SHA" ] && echo true || echo false)
HEAD_SHA="$NEW_HEAD_SHA"
```

### 4.D Exit condition

Exit the loop when **all** of:

- `UNRESOLVED == 0`
- `pst:code-review --sweep` reported `0 criticals` and `0 warnings`
- `PUSHED_IN_A == false` and `PUSHED_IN_C == false` (the round settled without touching code)

Otherwise increment `review_rounds` and continue. If `review_rounds == MAX_REVIEW_ROUNDS` without meeting the exit condition, halt and record residual:

```
Phase 4 stopped after {N} rounds.
Residual:
  - {U} unresolved threads
  - {C} code-review criticals / {W} warnings (see last --sweep output)

Resume with: /pst:ready $PR_URL
```

In `--dry-run` mode: pass `--dry-run` through to both sub-skills (both support it). Do not evaluate the "no pushes" exit condition (nothing can push); exit after one round with a preview.

Mark `review-loop` completed. Record `review_rounds` used.

---

## Phase 5 -- CI Wait + Auto-Fix (Pass 2)

Repeat Phase 3 verbatim against the (potentially new) `HEAD_SHA`. Phase 4 may have pushed commits that re-break CI -- this is the final green gate before handing the PR back to the human.

Use the same `MAX_CI_ATTEMPTS` budget, tracked separately as `ci_attempts_pass2` so the progress file stays informative.

If this phase halts with residual failures, emit the same report format as Phase 3, plus a note: "Review-loop commits changed the branch; a fresh CI run failed and could not be auto-fixed."

Mark `ci-wait-2` completed.

---

## Phase 6 -- Refresh PR Title and Description

This phase runs **only after CI pass 2 is green** (i.e., after Phase 5 has cleared). The branch is now the finished product; the PR body should describe what actually shipped, not what the branch looked like at opening.

### 6.1 Gather the source material

```bash
PR_BODY=$(gh pr view "$PR_NUMBER" --json body --jq .body)
PR_TITLE=$(gh pr view "$PR_NUMBER" --json title --jq .title)
COMMITS=$(git log --oneline "origin/$BASE_BRANCH..HEAD")
DIFF_STAT=$(git diff --stat "origin/$BASE_BRANCH..HEAD")
FILE_LIST=$(git diff --name-only "origin/$BASE_BRANCH..HEAD")
```

Read any top-of-file context that informs how this PR should be described:

- Project `CLAUDE.md` / `AGENTS.md` for house style (e.g., "keep PR titles under 70 chars", "always include a Test Plan section").
- `.context/` ADRs, architecture notes, patterns files -- surface relevant constraints.
- For each non-trivial changed file, read the diff hunks to understand intent.

### 6.2 Regenerate title and body

**Title:** under 70 characters, imperative mood, matches the narrative of the final commits (not just the initial intent). If the existing title already accurately reflects what shipped, keep it verbatim.

**Body sections (in this order):**

1. **Summary** -- 3-6 bullets covering what actually changed by end of branch, written from the current HEAD's perspective.
2. **Implementation Notes** -- key design decisions, invariants, or tradeoffs worth flagging to reviewers. Skip if nothing notable.
3. **Test plan** -- verifiable claims. Mix of auto-checkable items (code-level assertions, CI green, command outputs) and manual items (end-to-end scenarios, UI validation). Use `- [ ]` checkboxes; Phase 7 will tick the auto-validatable ones.

Preserve any existing `- [x]` items: text-match each checked item in the old body to the new body. If the new body contains the same item (same text, minus leading checkbox), keep it ticked. Never un-check a box the user or a prior validation run already ticked.

### 6.3 Update the PR

```bash
gh api "repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER" \
  --method PATCH \
  --field title="$NEW_TITLE" \
  --field body="$NEW_BODY"
```

If `gh pr edit` fails with a `read:org` scope error (common with restricted PATs), use the `gh api` REST path above as the primary -- it only needs `repo` scope.

Mark `refresh-pr` completed.

### 6.4 Dry-run behavior

In `--dry-run`: print the proposed title and body diff vs. the current PR, but do not `PATCH`.

---

## Phase 7 -- Test Plan Validation

This phase runs **only after Phase 6 has refreshed the PR body**, so it always validates against the latest test plan.

### 7.1 Parse the test plan

```bash
PR_BODY=$(gh pr view "$PR_NUMBER" --json body --jq .body)
```

Locate a heading that matches `^#+\s*Test\s*plan\s*$` (case-insensitive; also matches "Test Plan", "TEST PLAN"). Collect every `- [ ]` checkbox **under that heading** (until the next heading or end of body). Preserve each checkbox's position index so we can patch them in order later.

If no Test-plan heading is found OR no unchecked items exist, log `Test plan: nothing to validate` and skip to Phase 8.

### 7.2 Classify each item

For each unchecked checkbox, decide one of:

- **auto-validatable** -- the item describes something testable via code analysis, shell command, or PR state query. Signals: mentions of "build", "lint", "typecheck", "test", "format", "CI is green", specific file/symbol names, behaviour claims about the diff (e.g., "no regressions in auth", "handles null case in foo()").
- **manual-only** -- the item requires runtime/environment/stakeholder action. Signals: mentions of "browser", "staging", "UI looks", "stakeholder approval", "end-to-end scenario requiring a real second PR", "test in production".
- **ambiguous** -- can't confidently decide from the text alone. Treat as manual-only to be safe; do not validate, do not check.

### 7.3 Validate the auto-validatable ones

For each auto-validatable item, run the smallest sufficient check:

| Item kind                                                          | How to validate                                                                                                                      |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------ |
| "build passes" / "lint passes" / "typecheck passes" / "tests pass" | Run the repo's corresponding script; require exit 0. If script is missing, mark as manual-only with reason.                          |
| "CI is green" / "all checks passing"                               | `gh pr checks $PR_NUMBER --json bucket --jq 'all(.[]; .bucket == "pass" or .bucket == "skipping")'`. Require `true`.                 |
| "format is clean"                                                  | `pnpm run format:check` (or detected equivalent); exit 0.                                                                            |
| "no regressions in $subsystem"                                     | Confirm no files under relevant paths are newly failing existing tests. Inspect diff to show touched files + existing test coverage. |
| "$file contains $symbol / handles $case"                           | `grep` for the claim in the diff or current file contents; require match.                                                            |
| "no em dashes" / "no AI slop"                                      | Run `bash scripts/lint-no-emdash.sh` or the equivalent repo tooling; exit 0.                                                         |
| "rebased onto $base"                                               | `git merge-base --is-ancestor origin/$BASE_BRANCH HEAD`; exit 0.                                                                     |
| Anything else                                                      | Attempt to derive a minimal verification command from the text; if none obvious, demote to manual-only.                              |

Record each result as: `validated-pass` (check ran, exit 0), `validated-fail` (check ran, non-zero), or `demoted-manual` (couldn't derive a check).

### 7.4 Post the validation comment

Post **one** comment to the PR (not one per item) using `gh pr comment`. Shape:

```markdown
## Test plan validation

Ran against commit `{HEAD_SHA[:12]}` on `{HEAD_BRANCH}`.

**Auto-validated (checked off):** {N}

- `<checkbox text>` -- {one-line evidence, e.g., "pnpm run lint exited 0"}
- ...

**Failed validation (left unchecked):** {N}

- `<checkbox text>` -- {one-line failure summary + log excerpt if short}
- ...

**Manual verification required (left unchecked):** {N}

- `<checkbox text>` -- {why it can't be auto-checked, e.g., "requires a real second PR in another repo"}
- ...
```

If all three counts are 0, skip posting; just log `Test plan validation: no items to report`.

### 7.5 Tick the validated-pass boxes

Refetch the PR body (it may have changed since Phase 6 if an automation raced us), find each `validated-pass` checkbox by text, and replace its `- [ ]` with `- [x]`. Process from highest index to lowest to keep earlier positions stable.

```bash
gh api "repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER" \
  --method PATCH \
  --field body="$UPDATED_BODY"
```

Do not touch `validated-fail` or `manual-only` items -- the reviewer needs to see what's pending.

Mark `test-plan` completed. Record `test_plan: { validated, failed, manual }` counts in the progress file.

### 7.6 Dry-run behavior

In `--dry-run`: parse and classify as above, print the would-be comment and the would-be checkbox diff, but do not post or `PATCH`.

---

## Phase 8 -- Open & Summarize

Unless `--no-open` or `--dry-run`:

```bash
gh pr view "$PR_URL" --web
```

Print a final summary to the terminal:

```
/pst:ready complete for PR #{PR_NUMBER}
  Rebase:          onto {BASE_BRANCH}           ✓
  CI (pass 1):     green after {X} attempt(s)   ✓
  Review rounds:   {Y} of {MAX_REVIEW_ROUNDS}   ✓
  CI (pass 2):     green after {Z} attempt(s)   ✓
  PR refresh:      title + description updated  ✓
  Test plan:       {V} validated / {F} failed / {M} manual
  URL:             {PR_URL}

Residual: none
```

On success, delete `.pst-ready-progress.json`. On partial completion (halt in Phase 3, 4, 5, 6, or 7), keep it so a plain `/pst:ready $PR_URL` picks up where we left off.

---

## Dry-Run Summary

`--dry-run` flows through the whole pipeline in read-only mode:

- Phase 2: `pst:rebase --dry-run` -- analysis only.
- Phase 3: skip sub-agent fix attempts; print failing checks and their classifications.
- Phase 4: `pst:resolve-threads --dry-run` + `pst:code-review --sweep --dry-run`; report counts only.
- Phase 5: identical to Phase 3 under dry-run.
- Phase 6: print the proposed title and body diff; do not `PATCH` the PR.
- Phase 7: parse and classify the test plan; print the would-be comment and checkbox diff; do not post or `PATCH`.
- Phase 8: skip browser; print what the final summary would look like.

No pushes, no resolutions, no PR edits, no comments, no browser pops. Safe to run at any time to see the state of a PR.

---

## Progress File Shape

Written after every phase completes, at `$WORK_DIR/.pst-ready-progress.json`:

```json
{
  "pr_url": "https://github.com/owner/repo/pull/42",
  "pr_number": 42,
  "head_branch": "feature/x",
  "base_branch": "main",
  "head_sha": "{latest}",
  "work_dir": "/abs/path",
  "cross_repo": false,
  "state": "test-plan",
  "completed": [
    "intake",
    "workspace",
    "rebase",
    "ci-wait-1",
    "review-loop",
    "ci-wait-2",
    "refresh-pr"
  ],
  "skipped": [],
  "ci_attempts_pass1": 2,
  "ci_attempts_pass2": 0,
  "review_rounds": 1,
  "test_plan": { "validated": 3, "failed": 0, "manual": 4 },
  "residual": [],
  "updated_at": "2026-04-24T18:05:00Z"
}
```

---

## Stop Signals

**Per-PR (inside a child or single-PR run):** halt and preserve that PR's progress file when any of:

- Rebase produces conflicts that `pst:rebase` could not auto-resolve.
- `MAX_CI_ATTEMPTS` consumed in Phase 3 or Phase 5 with failures remaining.
- `MAX_REVIEW_ROUNDS` consumed in Phase 4 with unresolved threads or remaining criticals/warnings.
- Sub-agent fix attempts return no viable patch for every failing check in a round.
- `gh` auth fails, `git push --force-with-lease` is rejected, or the PR is closed/merged mid-run.

In dispatcher mode, a per-PR halt reports that PR as `BLOCKED` in the final matrix but does not stop sibling PRs. The dispatcher never aborts healthy children because one hit a residual.

**Dispatcher-level:** halt the whole run only when:

- `gh` or `git` is missing.
- All provided URLs are invalid or all return non-`OPEN` state.
- Temp-clone creation fails for every foreign-repo group (disk full, auth revoked, etc.).

Every halt prints a clear next-action line; resuming is always `/pst:ready <same URL(s)>`.

---

## Notes

- **Composition, not reimplementation.** Rebase, thread resolution, and code review live in their own skills. If their behavior changes, this skill inherits the change.
- **Force-push safety.** All pushes use `--force-with-lease`. The skill never uses `--force`.
- **Cross-repo friendly.** Runs from anywhere. For a single foreign-repo URL, clones to a temp dir and operates there. For multiple URLs spanning several repos, groups URLs by repo and shares one temp clone per foreign repo with per-PR worktrees inside. The user's cwd is never mutated.
- **Parallel by default for 2+ URLs.** Each PR is driven by its own background agent in its own worktree. Respects `--max-parallel` (default 4) to avoid GitHub API throttling. One crashed or blocked child does not affect its siblings.
- **Idempotent resume at both levels.** Per-PR progress files let an interrupted child pick up where it stopped. The dispatcher progress file lets a re-invocation skip already-`READY` children and re-dispatch only the `BLOCKED`/`ERROR` ones, reusing existing temp clones and worktrees.
