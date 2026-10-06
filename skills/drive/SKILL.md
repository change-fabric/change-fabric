---
name: cf:drive
description: "Drive a PR to an approved, green state end to end, in one of two modes. thorough (default): for a risky PR or a release range, interviews the owner, writes a review-and-QA planning set (plan.md, a capped goal.md, a segmented workflow.js, single-writer run templates), and prints a handoff prompt for a fresh session; it never runs the Workflow itself. quick: sweeps existing review threads, runs a relevance-gated local quality loop (code review, QA, refactor, slop) fixing what it finds, predicts CI locally, then pushes, waits for real CI green, and posts an approval, running straight through by default, with --signoff adding checkpoints before pushing and approving. Recurring review feedback stops the run and starts cf:plan."
---

# CF Drive

Drive a pull request, branch, or change set through review, fixes, CI, and
approval in one run.

Trigger: `/cf:drive [thorough|quick] <PR url or change set> [--area <name>] [--signoff]`.
Mode defaults to `thorough`.

## Parameters

| Name | Form | Default | Mode | Fills |
|---|---|---|---|---|
| mode | leading word `thorough` or `quick` | `thorough` | both | selects the section below |
| target | PR url, `owner/repo#n`, `#n`, branch, or change set (thorough also takes `base..head`) | required | both | quick: workflow args `files`, `isPR`, `headSha`; thorough: `{{target}}` |
| area | `--area <name>` | repo basename | thorough | plans subdirectory |
| signoff | `--signoff` flag | off: runs straight through | quick | whether checkpoints 1 and 2 pause |
| cap | internal | 4 | quick | workflow args `cap` |
| repo | resolved local checkout | current repo | both | quick: workflow args `repoPath`; thorough: `{{repo_path}}`, `{{repo_path_tilde}}` |
| base, head | resolved and pinned refs | from the PR or range | thorough | `{{base}}`, `{{head}}` |
| tier | tier check result, owner-confirmed | proposed at step 2 | thorough | `{{tier}}` |
| plan dir | `plan_paths.rb resolve` output | `<root>/<area>/<slug>` | thorough | `{{plan_dir}}`, `{{plan_dir_tilde}}`, `{{plan_path}}`, `{{goal_path}}`, `{{workflow_path}}`, `{{run_log_path}}` |
| skill dir | install path | `~/.claude/skills/cf:drive` | thorough | `{{skill_dir}}` |
| profile | newest sibling plan's `## Project profile` | empty | thorough | `{{profile}}` |
| sub-question | the part one scope agent owns | whole change | thorough | `{{sub_question}}` |
| ledger | verbatim interview answers | none | thorough | `{{decisions_ledger}}` |
| findings | scope agent reports, verbatim | none | thorough | `{{research_findings}}` |

The thorough workflow template keeps its own `FILL:` markers, filled by the
writing agent from the plan, not from these params.

## Modes

Parse the first word of the args. If it is `thorough` or `quick`, consume it;
otherwise the mode is `thorough` and the whole args string is the target.
`cf:sweep` always passes `quick` explicitly, since thorough stops for an
interview and refuses under away mode.

`quick` is the single-PR driver: it fixes, pushes, waits for CI, and approves.
`thorough` is a planner for a change too risky for one pass (money, auth, PII,
schema, a release range): it writes a planning set and hands off to a fresh
session, and never edits the target repo, commits, pushes, or calls `Workflow`.

## Quick mode

Question: would this change earn a real approval on GitHub, and is CI
actually green, not just plausibly so?

### Reference files

- `reference/workflow.js`: the Workflow script for the local quality-and-CI
  engine (steps 3-7 below). Read it, then pass its full contents verbatim as
  `Workflow`'s `script` argument.
- `reference/summaries.md`: the two 640-character checkpoint-summary formats
  and the approval-review body format (steps 8, 10, 11). Read before
  composing any of them.

### Sign-off

Quick mode runs straight through by default: no question from scope to
approval. `--signoff` adds two checkpoints, before pushing (step 8) and
before approving (step 10). A literal `full auto` or `auto` as the first or
last word of the args is stripped before parsing, with a one-line note that
full auto is already the default. Under away mode `--signoff` is ignored
and the run reports that it assumed the default. The one question the
default run can still bring is cf:plan's interview after a recurrence stop
(step 2b): it answers feedback that keeps recurring, not a sign-off.

### Scope

Accepted forms, resolved in the same order as `cf:code-review`'s step 1: a
PR URL, `owner/repo#123`, a bare `#123` (current repo when owner/repo is
omitted), a branch (diff against the default branch), an explicit file list
or glob, or a semantic feature description. The PR-scoped steps (both
resolve-threads sweeps, the CI poll, the approval, the browser-open) only
apply when the target resolves to a real PR. A non-PR scope runs the local
loop and CI prediction only; see Failure modes.

### Merge mode vs `--signoff`

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

(c) `--signoff` governs only whether the two checkpoints interrupt the
flow. It is fully orthogonal to merge mode.

By default under Local only: `cf:drive` runs the entire local pipeline
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

### Workflow

1. **(SKILL.md)** Determine scope as `files`, `repoPath`, `headSha`. PR: use
   PR-reading tools, fetch the head if not local. Else: `git diff`/`git
   show`/plain reads. Also run `ruby ~/.claude/cf/bin/skill_route.rb
   <files>` here in SKILL.md (the sandboxed Workflow script cannot shell
   out) and capture its stdout as `routeOutput` to pass in as an arg.
2. **(SKILL.md, PR scope only, hard floor, always runs regardless of
   `--signoff` or Haiku relevance results)** Pre-loop thread sweep:
   invoke `cf:resolve-threads` against the PR with the inline instruction
   `nested under cf:drive`: it runs straight through, replies and
   resolves what cites no commit, does not push (`cf:drive` owns the
   push), does not start cf:plan, and ends with its nested summary block,
   whose `pendingReplies` holds every `Fixed in <sha>` reply and
   resolution until that push lands (see step 8). Capture the counts and
   rationales for checkpoint 1. If the block is missing, unparseable, or
   carries `error: true`, stop here: no push, no approval [DR-1]. If the
   block's `truncated` is true, the review history is incomplete: stop and
   report it (no push, no approval). If its `plan` is not null, go to step
   2b.
2b. **(SKILL.md) Recurrence stop.** The thread sweep found a plan-sized
   root cause behind recurring feedback; another fix loop would only add a
   round. Under `--signoff`, first ask a checkpoint-1 question summarizing
   the sweep and the recurrence. The step-2 commits stay local; this stop
   never pushes, regardless of merge mode [DR-2]. Skip steps 3
   through 12: no quality loop, no CI poll, no approval, no browser-open.
   Then invoke the `cf:plan` skill with the Skill tool, args
   `<plan.seededGoal> --area <repo basename>`, and once it has written its
   handoff, run `ruby ~/.claude/cf/bin/ctx_store.rb archive
   plan-pending-<plan.slug>`. The block's `plan` is already settled and its
   pending pointer recorded by the nested sweep. Under away mode, or when
   invoked with `nested under cf:sweep`, do not start it: report the
   `plan-pending-<plan.slug>` pointer and `/cf:active` then `/cf:plan
   <seeded goal>`.
   The same no-push stop applies when the step-6b sweep or a pre-re-push
   sweep in step 9 returns a plan [DR-2].
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
   checkpoint 1 alongside step 2's sweep. A missing, unparseable, or
   `error: true` block, or a `truncated` block, stops the run as in step 2
   [DR-1]. If its `plan` is not null, take step 2b.
8. **(SKILL.md)** Checkpoint 1. One push gate, all of it required
   [DR-1]: `converged` is true, `ciPrediction.green` is true, neither
   sweep (step 2 or 6b) left a `needsHuman` or `conflicts` thread
   unaccepted, and both nested resolve-threads blocks were present and
   parseable with no `error: true` (the steps 2 and 6b stops apply first).
   Under
   `--signoff`: compose a summary, at most 640 characters, combining
   `execSummaryDraft` with both thread-sweep outcomes (per
   `reference/summaries.md`'s checkpoint-1 format), and ask for an explicit
   go/no-go; a yes there is the explicit acceptance that lets any
   `needsHuman` or `conflicts` thread stand as an exception. By default:
   skip the question, but if the gate above is unmet for any reason, stop
   and report it: no push, no approval. Either way, the push is
   additionally gated by the active cf merge mode: Local only means stop
   here and report (see Merge mode above); Merge ready/Admin bypass/Yolo
   proceed per their own normal push semantics (`cf:drive` only ever
   pushes here, never opens a new PR; the PR already exists by definition
   since this whole flow is PR-scoped from step 1 onward). Push the
   branch. Once the push lands, post every held `pendingReplies` entry
   from both sweeps (and from any pre-re-push sweep in step 9) and resolve
   its thread, but only after `git merge-base --is-ancestor <sha> HEAD`
   against the pushed branch confirms each entry's cited `commitSha`
   landed (resolve-threads RT-6); an entry whose sha fails that check gets
   no `Fixed in <sha>` reply, its thread stays open, and it is reported as
   a `conflicts` thread. Whenever the run stops without pushing (step 2b, an unmet
   gate, Local only), reply on those threads that the fix is committed
   locally but unpushed and leave them unresolved; never post a
   `Fixed in <sha>` reply for a commit GitHub cannot reach.
9. **(SKILL.md)** [DR-1][DR-3] Poll GitHub check-runs on the pushed commit until they
   resolve, counting only completed check runs: a repo with CI configured
   but zero completed runs for the SHA is not green, it is still pending.
   Give the poll a 30 minute deadline from the push; if check runs have
   not resolved by then, stop and report the still-pending jobs, do not
   proceed to checkpoint 2 or the approval. On a real CI failure: re-invoke
   the same `Workflow` (pass back
   the `scriptPath` the first call returned, plus `ciFixContext: {
   failingJobs: [...], logs: "..." }`) to fix locally, then re-enter step
   8's full gate (a fresh summary and question under `--signoff`; nothing
   by default) before re-pushing. Also re-run both resolve-threads sweeps
   (steps 2 and 6b) before each re-push, since a maintainer or bot may have
   commented in reaction to the push. Cap re-push attempts at 3; if CI
   still is not green after that, stop and report the persistent failing
   jobs, do not proceed to checkpoint 2.
10. **(SKILL.md)** Checkpoint 2. Once real CI is green: under
   `--signoff`, compose a second summary (at most 640 characters, per
   `reference/summaries.md`'s checkpoint-2 format: final diff state, CI
   result) and call `AskUserQuestion` for go/no-go. By default: skip
   both.
11. **(SKILL.md)** Resolve the PR author's login (`gh pr view --json
   author`) and the session's own login (`gh api user -q .login`). If they
   match, this is the user's own PR: skip the approval, do not call the
   review API at all, and report plainly that approval was skipped because
   the PR is the user's own [DR-3]. Otherwise post an actual GitHub PR
   approval review (`event: "APPROVE"`), `commit_id` set to the green SHA
   (the head commit that was just polled green, not whatever HEAD moved to
   meanwhile), body per `reference/summaries.md`'s approval-body format:
   plain prose, no praise, no AI-slop glyphs. If the approval call itself
   fails (permissions, a stale SHA), report plainly that the PR was not
   approved; never treat the call attempt as equivalent to approval.
   When nested under `cf:sweep`, always emit a fenced `drive-result` JSON
   block [DR-4] before returning: `{ approved, ciGreen, headSha,
   stoppedReason, noCi }`, `approved` and `ciGreen` both real-outcome
   booleans (never assumed true), `stoppedReason` null only when the run
   reached a terminal success state.
12. **(SKILL.md)** [DR-3] Immediately after the approval posts, in both modes,
   unconditionally: try to open the PR URL with the macOS `open` CLI
   (`open <url>`). If `open` is not available (check with `command -v
   open` first), skip silently and note it in the final report; never fail
   the run over this.

### Unattended gates

| ID | Action | Requires | When unmet |
|---|---|---|---|
| DR-1 | Push (step 8, and each re-push at step 9) | `converged && ciPrediction.green && needsHuman empty && conflicts empty`, both nested resolve-threads blocks present, parseable, and carrying no `error: true` | No push; stop and report |
| DR-2 | Push at the step-2b recurrence stop | Never; commits stay local | No push, regardless of merge mode |
| DR-3 | Approve | Real CI green on the pushed `headSha`, the PR is not the session's own, `commit_id` set to that `headSha` | Skip the approval and report it; never treat an attempted call as an approval |
| DR-4 | Emit the `drive-result` block when nested | Always, with real-outcome `approved`/`ciGreen` (never assumed true) | N/A, always emitted |
| DR-5 | Push a rebase commit to another contributor's branch (`rebase_then_merge`) | Allowed; drive performs the rebase and the push | N/A |

### Failure modes

- No PR resolvable (non-PR scope: branch/file-list/semantic description):
  steps 2, 6b, 9's poll, 11, and 12 have no target and are all skipped. The
  run is just the local loop (steps 1, 3-7) plus a final report describing
  the verdict it would have reached and the local CI prediction [DR-1][DR-3].
  State this plainly.
- Iteration cap reached without `converged` (the loop's would-approve check
  never passed): stop the loop, do not push or approve [DR-1], report the
  still-blocking findings per lane from the last iteration. Under
  `--signoff` this surfaces as a no-go recommendation at what would have
  been checkpoint 1; under the default, stop and report without ever
  reaching checkpoint 1 or pushing.
- CI never green after 3 re-push attempts (step 9): stop re-pushing, leave
  the last pushed commit as-is, report the persistent failing jobs and
  logs, do not proceed to checkpoint 2 or the approval [DR-1][DR-3].
- The step-9 poll hits its 30 minute deadline with checks still pending:
  stop, report the pending jobs, do not proceed to checkpoint 2 or the
  approval [DR-1][DR-3]; a repo with CI configured but zero completed runs
  for the SHA is pending, never read as green.
- The step-2 or step-6b nested resolve-threads block is missing,
  unparseable, or carries `error: true`: stop, no push, no approval [DR-1].
- The PR author is the session's own GitHub login: skip the approval and
  report it [DR-3]; this is not a failure, sweep's merge gate reads the
  `drive-result` block's `approved: false` and `stoppedReason` instead of
  waiting on a review that will never post.
- The approval API call fails: report that the PR was not approved [DR-3];
  never report success on the strength of having attempted the call.
- `open` CLI missing: handled inline in step 12 above, never fails the run.
- Haiku relevance call in the Workflow selects zero of the three gated skills
  (`cf:qa`, `cf:refactor`, `cf:change`): expected and fine for small/docs-only
  changes, and `cf:change` also self-skips in a repo with no `CHANGE.md`.
  `cf:code-review` and `cf:ai-slop` are floors and the two thread-sweep calls
  are floors; all four still run regardless of the Haiku call's outcome.
  Only `cf:qa`, `cf:refactor`, and `cf:change` are ever skipped.
- User answers "no" at either checkpoint under `--signoff`: do
  not abort destructively, do not auto-revert. Leave all local
  commits/fixes on disk as-is and stop the run, reporting the current
  state. At checkpoint 1 "no": stop before pushing [DR-1], local work is
  preserved for inspection or a future re-run. At checkpoint 2 "no": the
  commit is already pushed and CI is already green, so stop before
  approving [DR-3] and report that the PR is pushed and green but not
  approved. Neither "no" silently re-enters the iterate loop; re-invoking
  `/cf:drive` is how the user resumes.
- Recurrence stop (step 2b): not a failure. No push [DR-2]: the sweep's
  fix commits stay local. The run starts cf:plan (only reports the nested
  sweep's pending pointer under away or under cf:sweep), and reports the
  plan slug, the local commits, and the deferred threads.
- The `Workflow` call errors or returns no result: say so explicitly and
  stop; do not silently hand-apply fixes or push [DR-1].

## Thorough mode (default)

Question: can a separate session, with none of this one's context, take this
change from review to a ship or no-ship call without guessing a judgment the
owner should have made, and without repeating a mistake an earlier run already
paid for?

It shares `cf:plan`'s three-file contract, plans tree, and interview
discipline, and reuses its `plan_paths.rb` and `plan_check.rb` unchanged.

### What it produces

In `<root>/<area>/<slug>/` (`<root>` is `$CF_PLANS_ROOT`, default
`~/.claude/cf/plans`): `plan.md` (with `## Decisions (settled, do not
re-litigate)`, `## Project profile`, review units, severity, fix policy, the
gate, QA lanes, the handoff, workflow segments, and for a release with a
deploy in scope, the rehearsal, prod-day checklist and rollback), `goal.md`
(under 4000 characters), `workflow.js` (`reference/thorough/workflow-template.js`
with its PLAN block filled and its ENGINE half untouched), and the six
single-writer run files from `reference/thorough/templates/`. Then, to the
user only, a fenced handoff prompt for a fresh session.

### Thorough reference files

- `reference/thorough/interview.md`: the tier check and the eight decisions
  every thorough plan settles. Read it, and `skills/plan/reference/interview.md`,
  before asking anything.
- `reference/thorough/research-prompt.md`: the scope and writing agent
  prompts. Fill their placeholders; do not paraphrase them.
- `reference/thorough/workflow-template.js`: the engine; its header explains
  the PLAN/ENGINE split.
- `reference/thorough/templates/`: the six run files.
- `reference/thorough/handoff-prompt.md`: the step 10 handoff.

### Boundaries

- Writes only under `<root>`. Never edits the target repo, commits, or
  pushes; the merge mode governs the executing session, not this one.
- Never calls `Workflow`. The interview runs here, not in a subagent.
- Under away mode it refuses to start (the `mode_command.rb` hook says so),
  as `cf:plan` does: guessing these calls defeats the point.
- Project specifics (ports, database names, lane routes, flakes) live in the
  plan's `## Project profile`, never in this skill.

### Steps

1. **Identify the change.** A PR: `gh pr view <n> --json
   number,baseRefName,headRefName,title` for the refs only. A range: the two
   refs as given. Then `git -C <repo> fetch origin` and `git -C <repo>
   rev-parse origin/<base> origin/<head>` to pin both ends. Never `gh pr
   diff` (HTTP 406 above 300 files); read local ranges from here on.
2. **Check the tier** per `reference/thorough/interview.md` "The tier
   check". If it looks low, say so and recommend `/cf:drive quick` in one
   `AskUserQuestion`; continue only if the owner says to plan it anyway.
   Carry the proposed tier and matched files per area into step 5.
3. **Pick the destination.** Slug `pr-<n>-thorough` for a PR,
   `release-<head>-thorough` for a range, suffixed on collision. Run
   `ruby ~/.claude/cf/bin/plan_paths.rb resolve --slug <slug> [--area
   <area>]`, handle `area_exists` and `plan_dir_exists` as `cf:plan` steps 2
   and 3 do, then `plan_paths.rb mkdir`. The newest sibling plan.md with a
   `## Project profile` seeds the profile.
4. **Scope.** Spawn background agents (`general-purpose`, `model: opus`,
   `run_in_background: true`) from the research prompt's scope section: one
   for a PR, up to three for a release in one message (review units; QA and
   environment safety; deploy and data scripts). Each writes nothing and
   returns findings plus candidate questions; one that returns no questions
   has assumed something, so send it back once.
5. **Interview** per `reference/thorough/interview.md`: confirm the tier,
   then settle the eight decisions, up to four per `AskUserQuestion`, your
   recommendation first. Keep the verbatim ledger.
6. **Iterate.** `SendMessage` the scope agent the ledger and the narrow
   question the answers opened; interview again. At most three rounds; stop
   when a round changes nothing.
7. **Write.** One writing agent (`model: opus`) from the research prompt's
   writing section, with the full ledger and every finding pasted verbatim.
   Never two writers.
8. **Verify what landed.** All must pass:

   ```bash
   ruby ~/.claude/cf/bin/plan_check.rb <plan_dir>
   for f in review-findings qa-report gate-log followups owner-handoff run-log; do
     test -s "<plan_dir>/$f.md" || echo "MISSING $f.md"
   done
   diff <(sed -n '/^\/\/ ===== ENGINE/,$p' ~/.claude/skills/cf:drive/reference/thorough/workflow-template.js) \
        <(sed -n '/^\/\/ ===== ENGINE/,$p' <plan_dir>/workflow.js) && echo "engine unchanged"
   grep -c 'FILL:' <plan_dir>/workflow.js   # must print 0
   grep -l '{{' <plan_dir>/*.md             # must print nothing
   ```

   On failure, `SendMessage` the writing agent the exact output; up to two
   rounds, then report what still fails.
9. **Record a pointer.** Pipe `Thorough plan for <target>: <plan_dir>` to
   `ruby ~/.claude/cf/bin/ctx_store.rb capture --name thorough-<slug> --class
   active --desc "Thorough planning set for <target>, in flight."`.
10. **Emit the handoff.** Fill `reference/thorough/handoff-prompt.md`, print
    it as the final message in one fenced block, say plainly that nothing
    has run, report the tier, the interview rounds, and which decisions the
    answers changed. Stop.

### Thorough failure modes

- Assuming instead of asking, and asking instead of deciding: as in
  `cf:plan`. A profile fact carried from the last plan is evidence; a
  severity scale nobody confirmed is an assumption.
- The diff touches money, auth, PII or schema but no unit covers it: the
  workflow refuses such a plan. Add the unit at step 5.
- A lane that reaches a named target carries `--target-url`, a
  `--health-url` under it, and `--no-publish`, written into the lane. The
  workflow refuses a plan without them.
- A prior profile conflicts with the diff: ask about that item only.
- The writing agent errors or never reports: say so and stop. Do not
  hand-write the plan.
