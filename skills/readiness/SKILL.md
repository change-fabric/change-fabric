---
name: cf:readiness
description: Turns a pull request or a release range (such as development to production) into a planning set for reviewing, fixing and QA-ing it to a ship or no-ship decision. Classifies the diff first and sends a low-risk PR to cf:drive; otherwise background agents scope review units and QA lanes, this session interviews the user with AskUserQuestion, and a writing agent lands plan.md, a capped goal.md, a segmented workflow.js and single-writer run templates. It plans only; a separate session executes the workflow.
---

# CF Readiness

Trigger: `/cf:readiness <PR number or URL | base..head>` (optionally
`--area <name>`).

Question: can a separate session, with none of this one's context, take this
change from review to a ship or no-ship call without guessing a judgment the
owner should have made, and without repeating a mistake an earlier run already
paid for?

The review-and-QA sibling of `cf:plan`: same three-file contract, same plans
tree, same interview discipline. Where `cf:plan` plans a build, this plans the
path from "the change exists" to "the owner can decide to ship it".

## What it produces

In `<root>/<area>/<slug>/` (`<root>` is `$CF_PLANS_ROOT`, default
`~/.claude/cf/plans`), always all of:

- `plan.md` - execution-ready. `## Decisions (settled, do not re-litigate)`,
  `## Project profile`, review units, severity, fix policy, the gate, QA lanes,
  the handoff, workflow segments, and for a release with a deploy in scope, the
  rehearsal, prod-day checklist and rollback.
- `goal.md` - under 4000 characters, enforced.
- `workflow.js` - `reference/workflow-template.js` with its PLAN block filled
  and its ENGINE half untouched. Segments: `scope`, `review`, `fix`
  (`plan-batches`, `apply`, `verify`), `gate`, `qa`, `audit`, `handoff`, plus
  one pointer per main-thread-only step.
- The run files, each with one writer: `review-findings.md`, `qa-report.md`,
  `gate-log.md` and `followups.md` (the workflow's ledger agent),
  `owner-handoff.md` (the handoff agent), `run-log.md` (the main thread).

Then, to the user only, a fenced handoff prompt for a fresh session.

## Reference files

- `reference/interview.md`: the tier check and the eight decisions every
  readiness plan settles. Read it, and `skills/plan/reference/interview.md`,
  before asking anything.
- `reference/research-prompt.md`: the scope agent and writing agent prompts.
  Fill their placeholders; do not paraphrase them.
- `reference/workflow-template.js`: the engine. Its header explains the
  PLAN/ENGINE split.
- `reference/templates/`: the six run files.
- `reference/handoff-prompt.md`: the step 10 handoff.

## Relation to other skills

- `cf:drive` owns the low-risk single PR. This skill sends it there at step 2
  and writes nothing.
- `cf:plan` owns building something. Its `plan_paths.rb` and `plan_check.rb`
  do this skill's path and file checks unchanged.
- `cf:change` is part of the gate: when the repo has a `CHANGE.md` and the
  target branch is protected, the gate segment records a comprehensive run at
  the tip, which is what `change_merge_guard.rb` reads. QA lanes may also run
  targeted `change_run.rb` sweeps, always with pinned target flags.
- `cf:code-review` and `cf:qa` are single-pass tools. This skill plans many
  passes with owner gates between them; its reviewers and lanes are prompted
  from the plan, not by invoking those skills.

## Boundaries

- Writes only under `<root>`. Never edits a repo, commits or pushes; the
  session's merge mode is irrelevant here and governs the executing session.
- Never calls `Workflow`.
- The interview runs here, not in a subagent; `AskUserQuestion` is unavailable
  there.
- Under away mode it refuses to start (the `mode_command.rb` hook says so), as
  `cf:plan` does: guessing these calls defeats the point.
- Keeps project specifics (ports, database names, lane routes, flakes) in the
  plan's `## Project profile`, never in this skill.

## Workflow

1. **Resolve the change.** A PR: `gh pr view <n> --json
   number,baseRefName,headRefName,title` for the refs only. A range: the two
   refs as given. Then fetch and pin both ends:

   ```bash
   git -C <repo> fetch origin
   git -C <repo> rev-parse origin/<base> origin/<head>
   ```

   Never `gh pr diff`; it fails with HTTP 406 above 300 files. Everything
   after this reads local ranges.

2. **Check the tier.** Run the commands and path patterns in
   `reference/interview.md` "The tier check". Low risk: one `AskUserQuestion`
   with `cf:drive` recommended and "plan it as pr-high anyway" as the
   override; on `cf:drive`, say why and stop. Otherwise carry the proposed
   tier and the matched files per area into step 5.

3. **Resolve the destination.** Slug: `pr-<n>-readiness` for a PR,
   `release-<head>-readiness` for a range, suffixed when it collides.

   ```bash
   ruby ~/.claude/cf/bin/plan_paths.rb resolve --slug <slug> [--area <area>]
   ```

   Handle `area_exists` and `plan_dir_exists` exactly as `cf:plan` steps 2
   and 3 do, then `plan_paths.rb mkdir`. Look through `siblings` for the newest
   plan.md with a `## Project profile` section; that section seeds the
   profile.

4. **Scope.** Spawn background agents (`general-purpose`, `model: opus`,
   `run_in_background: true`) from `reference/research-prompt.md`'s scope
   section. One for a PR. Up to three for a release, in one message, split by
   part: review units, QA and environment safety, deploy and data scripts.
   Each writes nothing and returns findings plus candidate questions; one that
   returns no questions has assumed something, so send it back once.

5. **Interview.** Follow `reference/interview.md`: confirm the tier, then
   settle the eight decisions, up to four per `AskUserQuestion` call, each
   with your recommendation first. Keep the verbatim ledger.

6. **Iterate.** `SendMessage` the scope agent the ledger and the narrow
   question the answers opened; interview again. At most three rounds; stop
   when a round produces nothing that changes the plan.

7. **Write.** One writing agent (`model: opus`) from
   `reference/research-prompt.md`'s writing section, with the full ledger and
   every finding pasted verbatim. Never two writers.

8. **Verify what landed.** All must pass:

   ```bash
   ruby ~/.claude/cf/bin/plan_check.rb <plan_dir>
   for f in review-findings qa-report gate-log followups owner-handoff run-log; do
     test -s "<plan_dir>/$f.md" || echo "MISSING $f.md"
   done
   diff <(sed -n '/^\/\/ ===== ENGINE/,$p' ~/.claude/skills/cf:readiness/reference/workflow-template.js) \
        <(sed -n '/^\/\/ ===== ENGINE/,$p' <plan_dir>/workflow.js) && echo "engine unchanged"
   grep -c 'FILL:' <plan_dir>/workflow.js   # must print 0
   grep -l '{{' <plan_dir>/*.md             # must print nothing
   ```

   `plan_check.rb` covers the three core files (cap, glyphs, home paths, the
   Workflow contract). The rest prove the run files exist, the engine's guards
   survived, and no placeholder is left. On failure, `SendMessage` the writing
   agent the exact output; up to two rounds, then report what still fails.

9. **Record a pointer.**

   ```bash
   printf '%s' "Readiness plan for <target>: <plan_dir>" | \
     ruby ~/.claude/cf/bin/ctx_store.rb capture \
       --name readiness-<slug> --class active \
       --desc "Readiness planning set for <target>, in flight."
   ```

10. **Emit the handoff.** Fill `reference/handoff-prompt.md`, print it as the
    final message in one fenced block, and say plainly that nothing has run.
    Report the tier, the interview rounds, and which decisions the answers
    changed. Stop.

## Failure modes

- **Assuming instead of asking**, and **asking instead of deciding**: as in
  `cf:plan`. A profile fact carried from the last plan is evidence; a severity
  scale nobody confirmed is an assumption.
- A PR too large for `gh`: expected. Local ranges only, from step 1 on.
- The diff touches money, auth, PII or schema but no unit covers it: the
  workflow refuses to run such a plan. Add the unit at step 5.
- A lane needs to reach a named target: its command carries `--target-url`,
  a `--health-url` under it, and `--no-publish`, written into the lane, not
  left to the agent. The workflow refuses a plan without them.
- A prior plan's profile conflicts with the diff (a service gone, a new
  billable key): ask about that item only.
- The writing agent errors or never reports: say so and stop. Do not
  hand-write the plan.
