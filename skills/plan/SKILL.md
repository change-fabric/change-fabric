---
name: cf:plan
description: Turns a described goal into a landed planning set (plan.md, a goal.md capped at 4000 characters, and a runnable workflow.js) under the configured plans tree. Background Opus agents research and surface the open questions; this session grills the user with AskUserQuestion until the judgment calls are settled, then has the plan written against those answers. It plans only; it never implements the plan or runs the Workflow itself.
---

# CF Plan

Trigger: `/cf:plan <goal description>` (optionally `--area <name>`).

Question: is there a plan on disk detailed enough that a separate agent, with
none of this session's context, could turn it straight into real work, and are
the judgment calls in it the user's rather than yours?

## What it produces

Three files, always all three, in one directory:

- `<root>/<area>/<slug>/plan.md` - the full technical plan. No length cap.
  Execution-ready: named files, named commands, ordered phases, and a
  "Decisions (settled)" section recording what the user actually answered.
- `<root>/<area>/<slug>/goal.md` - the short vision statement. What done looks
  like and why it matters, with implementation detail deliberately left out.
  **Hard cap 4000 characters**, enforced mechanically.
- `<root>/<area>/<slug>/workflow.js` - a runnable Workflow script whose phases
  are the plan's own phases, so the executing session runs it rather than
  hand-authoring one from the plan.

`<root>` is `$CF_PLANS_ROOT`, defaulting to `~/.claude/cf/plans`, the shim's
own store beside `ctx`, `sessions`, and `bin`. Set `CF_PLANS_ROOT` to keep
plans in your own notes tree instead.

Then one more thing, to the user only: a fenced handoff prompt to paste into a
fresh session that will execute the plan.

## Reference files

- `reference/interview.md`: how to run the interview at steps 5 and 6. The
  core of this skill. Read it before asking anything.
- `reference/research-prompt.md`: the prompts given to the background agents.
  Read it and fill its placeholders; do not paraphrase it.
- `reference/workflow-template.js`: the annotated skeleton the writing agent
  instantiates as the plan's `workflow.js`, carrying the Workflow tool's
  authoring contract.
- `reference/handoff-prompt.md`: the handoff template emitted at step 10.

## Boundaries

- This skill writes only under `<root>`. It never edits a repo, never commits,
  never pushes. The session's cf merge mode is therefore irrelevant to it.
- It never calls `Workflow`. It authors a script; executing it is a separate
  session's job, started by the user pasting the step-10 prompt.
- **The interview happens here, in this session, not in a subagent.**
  `AskUserQuestion` is unavailable inside a subagent. Research agents surface
  candidate questions as structured output; you ask them.
- `cf:ctx` and this skill do not overlap: `.ctx` holds small durable notes in
  the shim store keyed by cwd; `cf:plan` writes large documents in the plans
  tree. Step 9 links the two with a one-line pointer doc.

## Workflow

1. **Resolve the destination.** Derive a 2 to 5 word kebab slug from the goal.
   Then run:

   ```bash
   ruby ~/.claude/cf/bin/plan_paths.rb resolve --slug <slug> [--area <area>]
   ```

   It prints JSON: `root`, `area`, `area_dir`, `area_exists`, `slug`,
   `plan_dir`, `plan_dir_exists`, `plan_md`, `goal_md`, `workflow_js`,
   `suggested_slug`, `siblings`. Use `--area` only when the invocation named
   one.

2. **Settle the destination.** Ask only when `area_exists` is false or
   `plan_dir_exists` is true. A new area means creating a new top-level
   directory: offer the inferred name and the nearest existing sibling. An
   existing plan directory: offer "extend the existing plan in place" and "use
   `<suggested_slug>`". Never overwrite silently, never delete. Fold this into
   the first interview batch at step 5 when nothing blocks research; ask it up
   front only when it changes what to research.

3. **Restate and create.** State the goal in two or three sentences, the
   chosen area, slug, and all three absolute paths. Then:

   ```bash
   ruby ~/.claude/cf/bin/plan_paths.rb mkdir --area <area> --slug <slug>
   ```

4. **Research.** Spawn background research agents with the `Agent` tool,
   `subagent_type: general-purpose`, `model: opus`, `run_in_background: true`,
   built from `reference/research-prompt.md`'s research section. One agent by
   default. Fan out to at most four, in a single message so they run
   concurrently, only when the goal splits into genuinely independent
   questions (different subsystems, different repos, different vendors).

   Every research agent writes no files. Each returns two things: what it
   found and recommends, and a list of **candidate questions** in the
   structured shape `reference/research-prompt.md` specifies. A research agent
   that returns findings but no candidate questions has almost certainly
   assumed something; send it back once.

5. **Interview, round one.** Read `reference/interview.md` and follow it. In
   short: merge the agents' candidate questions with your own, drop the ones
   you can settle from evidence, then call `AskUserQuestion` directly with up
   to four real decisions per call. Every question carries your own
   recommendation, labelled as such. Record each answer verbatim in a
   decisions ledger.

   Grill, do not survey. A question exists because the answer changes the
   plan. If both options produce the same plan, decide it yourself and say so.

6. **Iterate.** Answers open new questions; that is the point. Feed the ledger
   back to the research agent with `SendMessage` for a focused second pass
   scoped to what the answers changed, then interview again. Up to three
   rounds. Stop when a round surfaces no question whose answer would change
   the plan. Say which round settled it.

7. **Write.** Spawn one writing agent (`model: opus`) from
   `reference/research-prompt.md`'s writing section, with the full ledger and
   every research finding pasted in verbatim. It writes all three files. Never
   two writers. It must reproduce the ledger in plan.md under
   "Decisions (settled, do not re-litigate)", each decision naming the answer
   it came from, so the executing session does not reopen a settled call.

8. **Verify what landed.**

   ```bash
   ruby ~/.claude/cf/bin/plan_check.rb <plan_dir>
   ```

   It fails on a missing or empty file, a `goal.md` over 4000 characters, an
   AI-slop glyph, or a `workflow.js` that is missing its literal
   `export const meta = {` header, has no `phase()` call, or calls
   `Date.now()`, `Math.random()`, or `new Date()`. Do not report success until
   it exits zero.

   On failure, `SendMessage` the writing agent the checker's exact output and
   have it fix and re-run. Up to two rounds. If `goal.md` is still over cap
   after that, trim it yourself (cut implementation detail, which belongs in
   `plan.md`) and say so in the final report.

9. **Record a pointer.** One short `active`-class `.ctx` doc so a later
   session finds this plan:

   ```bash
   printf '%s' "Plan, goal, and workflow for <slug>: <plan_dir>" | \
     ruby ~/.claude/cf/bin/ctx_store.rb capture \
       --name plan-<slug> --class active \
       --desc "Planning set for <one-line goal>, in flight."
   ```

10. **Emit the handoff.** Fill `reference/handoff-prompt.md` and print it as
    the final message, in one fenced block, ready to copy. Say plainly that
    this skill has not run anything and that pasting the block into a fresh
    session is what starts execution. Report how many interview rounds ran and
    which decisions the user's answers changed. Stop here.

## Failure modes

- **Assuming instead of asking.** The failure this skill exists to prevent. If
  you wrote a decision into the plan that the user never saw, and a reasonable
  person could have gone the other way, that is a defect regardless of how
  good the plan reads.
- **Asking instead of deciding.** The opposite failure. Anything settled by
  reading the repo is yours to settle. Do not spend a question on it.
- Ambiguous or one-line goal with nothing to research: ask for the missing
  detail rather than spawning an agent to guess.
- A research agent returns nothing useful: report which question went
  unanswered. Put it to the user at step 5 rather than letting the writing
  agent invent an answer.
- A research agent tries to call `AskUserQuestion` and errors: expected, the
  tool is not available to subagents. Take its candidate questions and ask
  them yourself.
- `plan_check.rb` still failing after two rounds: handled inline at step 8.
- `plan_paths.rb` cannot resolve an area (cwd outside any project, no
  `--area`): ask for the area explicitly.
- The writing agent errors or never reports: say so explicitly and stop. Do
  not silently hand-write the plan yourself.
