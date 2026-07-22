---
name: cf:drive
description: Drive a PR to an approved, green state end to end. Sweeps existing review threads, runs a relevance-gated local quality loop (code review, QA, refactor, slop) fixing what it finds, predicts CI locally, then pushes, waits for real CI green, and posts an approval. Supports two sign-off modes, explicit checkpoints or full auto.
---

# CF Drive

Drive a pull request, branch, or change set through review, fixes, CI, and
approval in one run.

Trigger: `/cf:drive <PR url or change set>`.

Question: would this change earn a real approval on GitHub, and is CI
actually green, not just plausibly so?

## Reference files

- `reference/workflow.js`: the Workflow script for the local quality-and-CI
  engine (steps 3-7 below). Read it, then pass its full contents verbatim as
  `Workflow`'s `script` argument.
- `reference/summaries.md`: the two 640-character checkpoint-summary formats
  and the approval-review body format (steps 8, 10, 11). Read before
  composing any of them.

## Sign-off mode

Step 0, before resolving scope or doing any other work: call
`AskUserQuestion` exactly once.

- Question: "How should /cf:drive handle sign-off before pushing and
  before approving?"
- Header: "Sign-off"
- Option 1 (listed first, default/recommended): **Explicit sign-off** -
  "Pause at two checkpoints, before pushing and before approving, for your
  explicit go-ahead."
- Option 2: **Full auto** - "No pauses or questions of any kind after this.
  Run straight through to the approval non-interactively."

This is the only unconditional `AskUserQuestion` call in the entire skill.
Under Full auto, no further `AskUserQuestion` fires for the rest of the run,
including inside the two resolve-threads sweeps below. Store the answer for
the rest of the run.

## Scope

Accepted forms, resolved in the same order as `cf:code-review`'s step 1: a
PR URL, `owner/repo#123`, a bare `#123` (current repo when owner/repo is
omitted), a branch (diff against the default branch), an explicit file list
or glob, or a semantic feature description. The PR-scoped steps (both
resolve-threads sweeps, the CI poll, the approval, the browser-open) only
apply when the target resolves to a real PR. A non-PR scope runs the local
loop and CI prediction only; see Failure modes.

## Merge mode vs sign-off mode

Three independent axes:

(a) The outer session's own cf merge mode, the one running this
implementation session while `cf:drive` itself is being added or edited, is
irrelevant to `cf:drive`'s runtime behavior. It only governs how that
session lands its own change to this skill. It is not part of this skill's
own logic.

(b) A future invocation's active cf merge mode governs whether
`cf:drive`'s real GitHub-landing actions happen: the step-8 `git push`,
and (unrestricted, since it is a comment action) the step-11 approval.
Exactly like `cf:resolve-threads` SKILL.md's closing line about its own
push, the session's active cf merge mode governs whether that push
actually happens versus staying local. Steps 1 through 7 are local-only
regardless of merge mode; step 8's push is the first action merge mode
gates.

(c) The sign-off mode from step 0 governs only whether the two
`AskUserQuestion` checkpoints interrupt the flow. It is fully orthogonal to
merge mode.

Under Full auto plus Local only: `cf:drive` runs the entire local pipeline
(steps 1-7, both thread sweeps, the quality loop, local CI prediction) all
the way to a would-be-approved, would-be-green state, then stops cleanly at
the step-8 boundary and reports that it did not push or approve because the
active merge mode is Local only. It does not rely on the
`merge_mode_guard.rb` hook to block it partway through; steps 1-7 never
touch git push/PR actions at all, so the guard is never even invoked there.
`cf:drive`'s own logic checks the merge mode before attempting the step-8
push. Under Local only, at step 8 it skips the push, skips the CI poll (step
9), skips the approval (steps 10-11), emits a final report describing the
would-be-approved local state, and since nothing landed, also skips step
12's browser-open.

## Workflow

0. **(SKILL.md)** Sign-off mode question, as above. Store the answer for
   the rest of the run.
1. **(SKILL.md)** Resolve scope to `files`, `repoPath`, `headSha`. PR: use
   PR-reading tools, fetch the head if not local. Else: `git diff`/`git
   show`/plain reads. Also run `ruby ~/.claude/cf/bin/skill_route.rb
   <files>` here in SKILL.md (the sandboxed Workflow script cannot shell
   out) and capture its stdout as `routeOutput` to pass in as an arg.
2. **(SKILL.md, PR scope only, hard floor, always runs regardless of
   sign-off mode or Haiku relevance results)** Pre-loop thread sweep:
   invoke `cf:resolve-threads` against the PR, but explicitly instruct it
   inline to proceed automatically through its own report/reply/resolve
   steps with no `AskUserQuestion` of its own, and to not push (`cf:drive`
   owns the single push at step 8; resolve-threads' commits stay local and
   ride out with that push). Capture its `{ fixed, wontFix, needsHuman,
   conflicts }` counts and one-line rationales for use in step 8's
   checkpoint summary. This sweep's outcome never opens its own gate; it
   only contributes content to checkpoint 1.
3-7. **(One `Workflow` call)** Read `reference/workflow.js` and pass its
   contents verbatim as `script`, with `args: { files, repoPath, headSha,
   routeOutput, isPR, cap: 4, ciFixContext: null }`. This call does
   relevance detection (Haiku), the iterate-and-fix quality loop with a
   would-approve recheck each iteration (cap default 4, within the
   requested 3-5 band), and local CI prediction. See
   `reference/workflow.js` for the phase breakdown. It returns `{
   selectedSkills, routeSummary, relevance, iterations, converged,
   iterationCap, ciPrediction, fixesSummary, execSummaryDraft }`.
6b. **(SKILL.md, PR scope only, hard floor, same non-pausing rule as step
   2)** Post-loop thread sweep: once the Workflow call above returns,
   invoke `cf:resolve-threads` again the same way, to catch anything that
   landed on the PR while the loop was iterating. Fold its outcome into
   checkpoint 1 alongside step 2's sweep.
8. **(SKILL.md)** Checkpoint 1. Only proceed once `ciPrediction.green` is
   true. Under Explicit sign-off: compose a summary, at most 640
   characters, combining `execSummaryDraft` with both thread-sweep
   outcomes (per `reference/summaries.md`'s checkpoint-1 format), call
   `AskUserQuestion` for an explicit go/no-go. Under Full auto: skip the
   summary and the question entirely. Either way, this push is
   additionally gated by the active cf merge mode: Local only means stop
   here and report (see Merge mode above); Merge ready/Admin bypass/Yolo
   proceed per their own normal push semantics (`cf:drive` only ever
   pushes here, never opens a new PR; the PR already exists by definition
   since this whole flow is PR-scoped from step 1 onward). Push the
   branch.
9. **(SKILL.md)** Poll GitHub check-runs on the pushed commit until they
   resolve. On a real CI failure: re-invoke the same `Workflow` (pass back
   the `scriptPath` the first call returned, plus `ciFixContext: {
   failingJobs: [...], logs: "..." }`) to fix locally, then re-enter step
   8's full gate (a fresh summary + question under Explicit; nothing under
   Full auto) before re-pushing. Also re-run both resolve-threads sweeps
   (steps 2 and 6b) before each re-push, since a maintainer or bot may have
   commented in reaction to the push. Cap re-push attempts at 3; if CI
   still is not green after that, stop and report the persistent failing
   jobs, do not proceed to checkpoint 2.
10. **(SKILL.md)** Checkpoint 2. Once real CI is green: under Explicit
   sign-off, compose a second summary (at most 640 characters, per
   `reference/summaries.md`'s checkpoint-2 format: final diff state, CI
   result) and call `AskUserQuestion` for go/no-go. Under Full auto: skip
   both.
11. **(SKILL.md)** Post an actual GitHub PR approval review (`event:
   "APPROVE"`), body per `reference/summaries.md`'s approval-body format:
   plain prose, no praise, no AI-slop glyphs.
12. **(SKILL.md)** Immediately after the approval posts, in both modes,
   unconditionally: try to open the PR URL with the macOS `open` CLI
   (`open <url>`). If `open` is not available (check with `command -v
   open` first), skip silently and note it in the final report; never fail
   the run over this.

## Failure modes

- No PR resolvable (non-PR scope: branch/file-list/semantic description):
  steps 2, 6b, 9's poll, 11, and 12 have no target and are all skipped. The
  run is just the local loop (steps 1, 3-7) plus a final report describing
  the would-be-approve verdict and the local CI prediction. State this
  plainly.
- Iteration cap reached without `converged` (the loop's would-approve check
  never passed): stop the loop, do not push or approve, report the still-
  blocking findings per lane from the last iteration. Under Explicit this
  surfaces as a no-go recommendation at what would have been checkpoint 1;
  under Full auto, stop and report without ever reaching checkpoint 1 or
  pushing.
- CI never green after 3 re-push attempts (step 9): stop re-pushing, leave
  the last pushed commit as-is, report the persistent failing jobs and
  logs, do not proceed to checkpoint 2 or the approval.
- `open` CLI missing: handled inline in step 12 above, never fails the run.
- Haiku relevance call in the Workflow selects zero of the three gated skills
  (`cf:qa`, `cf:refactor`, `cf:change`): expected and fine for small/docs-only
  changes, and `cf:change` also self-skips in a repo with no `CHANGE.md`.
  `cf:code-review` and `cf:ai-slop` are floors and the two resolve-threads
  sweeps are floors; all four still run regardless of the Haiku call's outcome.
  Only `cf:qa`, `cf:refactor`, and `cf:change` are ever skipped.
- User answers "no" at either checkpoint under Explicit sign-off mode: do
  not abort destructively, do not auto-revert. Leave all local
  commits/fixes on disk as-is and stop the run, reporting the current
  state. At checkpoint 1 "no": stop before pushing, local work is
  preserved for inspection or a future re-run. At checkpoint 2 "no": the
  commit is already pushed and CI is already green, so stop before
  approving and report that the PR is pushed and green but not approved.
  Neither "no" silently re-enters the iterate loop; re-invoking
  `/cf:drive` is how the user resumes.
- The `Workflow` call errors or returns no result: say so explicitly and
  stop; do not silently hand-apply fixes or push.
