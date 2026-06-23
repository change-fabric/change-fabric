---
name: pst:ready
description: Bring one or many open PRs to merge-ready state. v2 adds a tournament repair phase -- 3 parallel Sonnet strategies (Conservative/Structural/Review-first) scored by an Opus judge; winner is cherry-picked before settling, PR refresh, and push.
argument-hint: "<PR-URL> [<PR-URL>...] [--merge] [--dry-run] [--no-open] [--no-settle] [--max-ci-attempts N] [--max-review-rounds N] [--max-parallel N]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, AskUserQuestion, Skill
---

# Bring PRs to Merge-Ready (v2 -- Tournament Protocol)

Drive PRs to merge-ready state. Single PR: run inline. 2+ URLs: dispatcher.

Pipeline: workspace setup (0-1) --> tournament repair (T) --> settling (5.5)
--> PR refresh (6) --> test-plan (7) --> open and summarize (8).

## Input

<arguments> #$ARGUMENTS </arguments>

Flags: `--merge`, `--dry-run`, `--no-open`, `--no-settle`,
`--max-ci-attempts N` (default 3), `--max-review-rounds N` (default 5),
`--max-parallel N` (dispatcher, default 4).

Validate: PR URLs must match `https://github.com/.+/.+/pull/\d+`. Reject bare
numbers. De-duplicate silently. Require `gh` and `git`.

---

## Phase 0 -- Intake and Guards

```bash
PR_JSON=$(gh pr view "$PR_URL" \
  --json number,url,title,state,isDraft,headRefName,headRefOid,baseRefName,mergeable)
```

Stop if `state != OPEN`. Ask (AskUserQuestion) to proceed if `isDraft`.
Proceed through `CONFLICTING` -- the repair phase resolves it.

---

## Phase 1 -- Workspace Setup

**Same-repo:** worktree at `$REPO_ROOT/.worktrees/ready-PR-$PR_NUMBER` on
`$HEAD_BRANCH` (non-detached so repair can push back).

**Cross-repo:** `gh repo clone $PR_OWNER_REPO $WORK_DIR -- --depth=50` then
`gh pr checkout $PR_NUMBER`.

Set `WORK_DIR`. Add `.pst-ready-progress.json` to `.git/info/exclude`. Write
initial progress (`state`, `completed[]`, metadata). If a progress file from
the last 24 h exists, resume from the first phase not in `completed[]`.

All subsequent commands run inside `$WORK_DIR`.

---

## Tournament Gate

Ask the user (AskUserQuestion):

> Run N=3 repair strategies in parallel? (Yes / Single-path / Abort)

- **Yes:** run Phase T tournament below.
- **Single-path:** run Strategy B only; skip the judge; cherry-pick its commits
  directly in Phase T.3.
- **Abort:** stop cleanly.

In `--dry-run`: skip the gate; log "dry-run: would run tournament N=3" and
continue in read-only mode through all phases.

---

## Phase T -- Repair Tournament

**Phase T setup:** Create 3 isolated sub-worktrees of the PR repo before
spawning agents:

```bash
git -C "$WORK_DIR" worktree add "$WORK_DIR/.tournament/strategy-a" "$HEAD_BRANCH"
git -C "$WORK_DIR" worktree add "$WORK_DIR/.tournament/strategy-b" "$HEAD_BRANCH"
git -C "$WORK_DIR" worktree add "$WORK_DIR/.tournament/strategy-c" "$HEAD_BRANCH"
```

Spawn **3 foreground Sonnet agents** in a single response turn (no
`run_in_background`). They run concurrently and all must finish before the
judge. Do NOT use `isolation: worktree` -- each agent gets its own PR-repo
sub-worktree, not an isolation of the skills repo.

Each agent receives: `PR_URL`, `PR_NUMBER`, `HEAD_BRANCH`, `BASE_BRANCH`,
`HEAD_SHA`, `WORK_DIR`, `AGENT_WORK_DIR` (its sub-worktree path),
`MAX_CI_ATTEMPTS`, `MAX_REVIEW_ROUNDS`, and its strategy directive.

### Strategy A -- Conservative

- Rebase: prefer merge over rebase when conflicts exist.
- CI: one `pst:code-review` + fix-sub-agent pass; stop after that budget.
- Threads: run `pst:resolve-threads` for bot-posted threads only
  (`github-actions[bot]`, `codex`, `copilot-pull-request-reviewer`).
- Skip the adversarial code-review settling loop.
- All git operations are local to your AGENT_WORK_DIR. Do NOT push to remote.
  Do NOT invoke sub-skills that push (pst:rebase, pst:resolve-threads,
  pst:code-review are allowed read-only or with --no-push; check each before
  calling). The orchestrator handles the push after cherry-picking the winner.

### Strategy B -- Structural

- Full `pst:rebase`; squash fixup commits (`git rebase -i --autosquash`).
- Parallel CI-fix sub-agents, one per failing check.
- After CI is green, run `pst:resolve-threads` and `pst:code-review --sweep`
  in parallel.
- All git operations are local to your AGENT_WORK_DIR. Do NOT push to remote.
  Do NOT invoke sub-skills that push (pst:rebase, pst:resolve-threads,
  pst:code-review are allowed read-only or with --no-push; check each before
  calling). The orchestrator handles the push after cherry-picking the winner.

### Strategy C -- Review-first

- Run `pst:code-review --sweep` first to surface structural issues before
  touching threads.
- Resolve only threads that survive after code-review (skip threads that
  code-review would invalidate).
- CI fix only for issues code-review explicitly flags as auto-fixable.
- All git operations are local to your AGENT_WORK_DIR. Do NOT push to remote.
  Do NOT invoke sub-skills that push (pst:rebase, pst:resolve-threads,
  pst:code-review are allowed read-only or with --no-push; check each before
  calling). The orchestrator handles the push after cherry-picking the winner.

### Required result block

Each agent must end its response with:

```
---ready-result---
STRATEGY: <A|B|C>
STATUS: ready | blocked: <reason>
HEAD_SHA: <full 40-char sha from: git rev-parse HEAD>
CI_ATTEMPTS: <integer: how many CI fix passes were run>
OPEN_THREADS: <integer: from gh api graphql reviewThreads where isResolved=false>
DIFF_STAT:
<output of: git diff --stat origin/$BASE_BRANCH..HEAD>
DIFF:
<output of: git diff origin/$BASE_BRANCH..HEAD | head -n 500>
---end-ready-result---
```

If **all 3 agents** are `blocked`, report all reasons and stop. Do not advance
to the judge.

After each tournament agent returns, append its parsed result to the progress
file under key `tournament_results.{A|B|C}`. On resume within Phase T, read
`tournament_results` from the progress file and only re-spawn missing strategies
(those not already present in the progress file).

---

## Phase T.2 -- Opus Judge

Parse every `---ready-result---` block. Collect diffs for `STATUS: ready`
agents. If exactly one agent is `ready`, skip the judge and use it as the
winner.

Otherwise, spawn one **foreground Opus agent** (`model: opus`) before Phase
T.3. Agent input: all ready DIFF_STAT summaries and capped diffs (500 lines
max per strategy) plus this prompt:

> Score each strategy on three axes (1-5 each):
>
> - **Commit graph cleanliness**: squashed, atomic, no merge commits.
> - **CI attempts consumed**: fewer is better.
> - **Review residuals remaining**: unresolved threads, open findings.
>
> Return JSON only -- no prose before or after:
>
> ```json
> {
>   "winner": "A|B|C",
>   "scores": {
>     "A": { "graph": 0, "ci_attempts": 0, "residuals": 0 },
>     "B": { "graph": 0, "ci_attempts": 0, "residuals": 0 },
>     "C": { "graph": 0, "ci_attempts": 0, "residuals": 0 }
>   },
>   "reasoning": "one sentence"
> }
> ```

Log the scores and reasoning before proceeding.

---

## Phase T.3 -- Cherry-pick Winner

Read `HEAD_SHA` from the winning strategy's result block. Cherry-pick the
winner's commits onto `$WORK_DIR`:

```bash
WINNER_COMMITS=$(git log --reverse --format="%H" origin/$BASE_BRANCH..$WINNER_SHA)
for SHA in $WINNER_COMMITS; do
  git cherry-pick "$SHA"
done
git push --force-with-lease origin "$HEAD_BRANCH"
HEAD_SHA=$(git rev-parse "origin/$HEAD_BRANCH")
```

If cherry-pick conflicts, abort and reset to the winner's branch:

```bash
git cherry-pick --abort
git reset --hard $WINNER_SHA
git push --force-with-lease origin "$HEAD_BRANCH"
```

---

## Phase 5.5 -- Eager Settling Loop

Skipped with `--no-settle` or `--dry-run`.

Poll every 180 s (`--settle-interval`). Exit after 3 consecutive clean polls.
Hard timeout: 1800 s (`--settle-timeout`).

Per poll: check for failing CI checks, new unresolved threads (GraphQL
`reviewThreads`), and blocking PR comments (`scripts/scan-blocking-comments.sh`
or inline `gh api` fallback). On a failing check, spawn a CI-fix sub-agent
(isolated worktree), parse `CI_FIX_RESULT={...}`, cherry-pick, push. On new
threads, run `pst:resolve-threads "$PR_URL"`.

Reset `consecutive_clean` to 0 on any remediation. On timeout or unfixable
remediation, halt with a residual report and preserve the progress file.

---

## Phase 6 -- Refresh PR Title and Description

Gather commit log, diff-stat, and existing PR body. Regenerate title (under 70
chars, imperative) and body (Summary bullets, Implementation Notes if notable,
Test Plan checkboxes). Preserve existing `- [x]` boxes. Push via
`gh api repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER --method PATCH`.

---

## Phase 7 -- Test Plan Validation

**Mandatory.** Cannot be skipped even if all items appear manual. Every item must
be classified and documented.

Parse all `- [ ]` items under a `Test plan` heading. Classify each into one of
three buckets:

- **Shell-executable**: contains a command runnable in the PR worktree: `grep`,
  `find`, `curl` (localhost/loopback), `git`, `docker`, `pnpm`/`npm`/`ruby`/
  `python` invocations, lint, typecheck, build commands. Run these.
- **Environment-dependent**: requires a live external service, remote URL,
  physical hardware, or credentials not present in the worktree. Skip with a
  labeled reason.
- **Narrative/manual**: describes a human action with no shell equivalent. Skip
  with a labeled reason.

**Execution (shell-executable items):** Run each command in `$WORK_DIR`. Capture
stdout, stderr, and exit code. Pass = exit 0 (or non-empty output when the item
asserts "returns X" or "outputs Y"). Fail = non-zero exit or empty when output is
expected.

**PATCH the PR body:** tick `- [x]` for each passing item. Leave `- [ ]` for
failures. Append ` _(skipped: <reason>)_` inline after each skipped item (either
bucket). Push via:

```bash
gh api repos/$PR_OWNER/$PR_REPO/pulls/$PR_NUMBER \
  --method PATCH --field body="$UPDATED_BODY"
```

**Post one validation comment** tagged `<!-- pst:test-plan-validation -->` with a
results table:

| Item | Bucket                | Result  | Output snippet                |
| ---- | --------------------- | ------- | ----------------------------- |
| ...  | shell-executable      | PASS    | `<first 120 chars of stdout>` |
| ...  | environment-dependent | SKIPPED | no live DB                    |
| ...  | narrative             | SKIPPED | manual UI action              |

Do not skip this phase. If there is no `Test plan` heading, note that in the
attestation comment (Phase 8) and continue.

---

## Phase 8 -- Open and Summarize

Post an attestation comment (`<!-- pst:ready-attestation -->`). Unless
`--no-open`, `gh pr view "$PR_URL" --web`. Print a terminal summary.

Delete `.pst-ready-progress.json` on success. Preserve on any halt.

If `--merge`: `gh pr merge $PR_NUMBER --squash`, confirm the merge commit on
base, wait for post-merge CI, then delete the progress file. Preserve and warn
on post-merge CI failure.

---

## Dispatcher (2+ URLs)

Group URLs by `owner/repo`. Pre-create worktrees for same-repo PRs at
`$REPO_ROOT/.worktrees/ready-PR-$N`; for foreign repos, clone to one shared
temp dir per repo. Spawn background child agents (capped at `--max-parallel`);
each runs Phases 0-8 and emits on its final line:

```
PST_READY_CHILD_RESULT={"pr_url":"...","status":"READY|BLOCKED|SKIPPED",...}
```

Print a status matrix. Open READY PRs (or all with `--open-all`). On
`BLOCKED`/`ERROR`, preserve the dispatcher progress file so a re-run
re-dispatches only failed children.

---

## Notes

- All pushes use `--force-with-lease`. Never bare `--force`.
- Tournament agents run in isolated sub-worktrees; their commits land on the
  real branch only after the winner is cherry-picked in Phase T.3.
- Resume: `completed[]` lets `/pst:ready $PR_URL` resume from the first
  incomplete phase; tournament gate re-appears if Phase T did not finish.
- Composition: delegates to `pst:rebase`, `pst:resolve-threads`, `pst:code-review`.
