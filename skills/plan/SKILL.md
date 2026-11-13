---
name: cf:plan
group: workflow
description: Turns a described goal into a landed planning set under the configured plans tree. The set is plan.md, a goal.md capped at 4000 characters, and a runnable workflow.js. Background Opus agents research and surface the open questions; this session grills the user with AskUserQuestion until the judgment calls are settled, then has the plan written against those answers. It plans only; it never implements the plan or runs the Workflow itself.
---

# CF Plan

Trigger: `/cf:plan <goal description>` (optionally `--area <name>`,
`--seed <file>`, `--judge`).

`--seed <file>` names a prior brainstorm, typically the `brainstorm.md` that
cf:brainstorm landed and whose handoff line already carries this flag. Its
text feeds the research and writing prompts through their `{{seed}}` section.

Question: is there a plan on disk detailed enough that a separate agent, with
none of this session's context, could turn it straight into real work, and are
the judgment calls in it the user's rather than yours?

`--judge` replaces the human interview at steps 5 and 6 with an LLM-as-judge
interview. Per open question, 2 to 3 background proposer agents with distinct
briefs each propose an answer with rationale, and one judge agent (opus)
picks or merges them. Each ledger entry then carries `Answered by: judge`,
and plan.md lists those entries under `### Judged decisions (unreviewed)`
so they stay open to revisiting. This is distinct from away mode, which only
takes recommended defaults. Use `--judge` only when the caller's merge mode is
admin-bypass (for example cf:sweep stack mode after a resolve-threads
recurrence); under merge-ready the human interview always runs, and the flag
is ignored with a one-line note. The protocol is in `reference/interview.md`.

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
- `reference/visualize-prompt.md`: the brief for the step 7a diagram agent.

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

1. **Resolve the destination.** Derive a 2 to 5 word kebab slug from the goal,
   except when `--seed` names a file called `brainstorm.md`: then the slug is
   the name of the seed's parent directory, and the area (unless `--area` was
   given) is the name of that directory's parent, so the plan extends the
   brainstorm's own directory. Then run:

   ```bash
   ruby ~/.claude/cf/bin/plan_paths.rb resolve --slug <slug> [--area <area>]
   ```

   It prints JSON: `root`, `area`, `area_dir`, `area_exists`, `slug`,
   `plan_dir`, `plan_dir_exists`, `plan_md`, `goal_md`, `workflow_js`,
   `suggested_slug`, `siblings`, plus a `_tilde` twin of every path field
   (`root_tilde`, `area_dir_tilde`, `plan_dir_tilde`, `plan_md_tilde`,
   `goal_md_tilde`, `workflow_js_tilde`). Use `--area` only when the
   invocation named one.

   If `--seed <file>` was given, expand a leading `~` against your own home
   and read the file now. If it is missing or unreadable, stop with a clear
   error naming the expanded path; never plan without a seed that was asked
   for. Keep its full text for steps 4 and 7.

   Use the absolute fields for real filesystem operations (mkdir, Read,
   Write) on this machine. Use the `_tilde` fields for any text you write
   into `plan.md`, `goal.md`, `workflow.js`, or the step-10 handoff prompt:
   the plan directory lives under a user's home, and a literal absolute path
   like `/Users/pxt/...` or `/home/exe/...` breaks the moment the plan is
   carried (by `rsync` or similar) to a machine where the same account has a
   different literal home path (`/Users/PST/...`). For any other absolute
   path outside this JSON, notably the repo root passed to research and
   writing agents, get its tilde form the same way:

   ```bash
   ruby ~/.claude/cf/bin/plan_paths.rb tildeize --path <absolute-path>
   ```

2. **Settle the destination.** Ask only when `area_exists` is false or
   `plan_dir_exists` is true. A new area means creating a new top-level
   directory: offer the inferred name and the nearest existing sibling. An
   existing plan directory: offer "extend the existing plan in place" and "use
   `<suggested_slug>`". Never overwrite silently, never delete. Fold this into
   the first interview batch at step 5 when nothing blocks research; ask it up
   front only when it changes what to research.

   Exception: when a seed was given and its expanded path sits inside the
   resolved `plan_dir` (compare expanded absolute paths), skip the collision
   question and extend the existing plan in place, saying so in one line. The
   seed landing there is cf:brainstorm's own hand-off, not a collision.

3. **Restate and create.** State the goal in two or three sentences, the
   chosen area, slug, and all three absolute paths. Then:

   ```bash
   ruby ~/.claude/cf/bin/plan_paths.rb mkdir --area <area> --slug <slug>
   ```

4. **Research.** Spawn background research agents with the `Agent` tool,
   `subagent_type: general-purpose`, `model: opus`, `run_in_background: true`,
   built from `reference/research-prompt.md`'s research section, with
   `{{seed}}` filled from step 1 or rendered empty. One agent by
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
   decisions ledger. Under `--judge` (admin-bypass only), run the judge
   protocol from `reference/interview.md` instead of `AskUserQuestion`.

   Grill, do not survey. A question exists because the answer changes the
   plan. If both options produce the same plan, decide it yourself and say so.

6. **Iterate.** Answers open new questions; that is the point. Feed the ledger
   back to the research agent with `SendMessage` for a focused second pass
   scoped to what the answers changed, then interview again. Up to three
   rounds. Stop when a round surfaces no question whose answer would change
   the plan. Say which round settled it.

7. **Write.** Spawn one writing agent (`model: opus`) from
   `reference/research-prompt.md`'s writing section, with the full ledger and
   every research finding pasted in verbatim, and `{{seed}}` filled the same
   way as at step 4. It writes all three files. Never
   two writers. It must reproduce the ledger in plan.md under
   "Decisions (settled, do not re-litigate)", each decision naming the answer
   it came from, so the executing session does not reopen a settled call.
   It ends plan.md with a `## Visuals` section listing the visuals the
   scale rule below calls for, one line each (file name, type, purpose),
   without drawing them. With none, the section reads "None (single-PR,
   single-subsystem plan)." Keep the writing agent's id for 7a and 7b.

   Scale rule (deterministic):

   - 0 visuals for a single-PR plan that touches one subsystem.
   - 1 visual for a multi-phase plan, normally a flow or an architecture
     diagram.
   - Up to 3 diagrams when the plan crosses subsystems or services
     (architecture plus sequence or state). Add a cf:diagram timeline or a
     cf:chart schedule when the plan has 4 or more phases.
   - A data chart only when plan.md carries a real numeric table, such as
     load targets, cost, or sizes.

7a. **Visualize.** Skipped when the `## Visuals` list is empty. Otherwise
   spawn one background diagram agent (`model: opus`) from
   `reference/visualize-prompt.md`. It authors diagrams per cf:diagram and
   charts per cf:chart into `<plan_dir>/diagrams/`, reads the palette with
   `--repo <target repo>`, lints for up to 3 rounds (retrying with
   `--no-measure` on exit 3), renders light and dark PNGs with
   `diagram_render.rb` (skipping on exit 3), and never edits the three plan
   files. It returns each SVG with type, purpose, and measured yes or no.
   Then `SendMessage` the writing agent to fill `## Visuals` from that
   return: each SVG's relative path, type, purpose, and "text measured" or
   "text not measured (no Docker)", plus a note that diagrams are
   illustrative and plan.md wins on any conflict. A visual still failing
   lint after 3 rounds is dropped and noted there; a picture never blocks
   the plan.

7b. **Roast.** Always runs, here in the main session, estimate first. Cap:
   at most 2 rounds and 0.50 USD in total, tracked by summing the per-round
   estimates. Never raise the cap.

   1. Inputs: `--brief <plan_dir>/goal.md --text plan.md --text goal.md`,
      one `--shot` for every
      `-light.png` and `-dark.png` under `diagrams/`, `--kind arch` when an
      architecture diagram exists (else `--kind doc`),
      `--audience "the engineer executing this plan in a fresh session"`,
      `--purpose` set to goal.md's outcomes, and
      `--out-dir <plan_dir>/roast`. The script is
      `ruby ~/.claude/cf/bin/roast.rb`.
   2. Run with `--estimate-only` first and show the estimate. If round 1 is
      over 0.50 USD, shorten the inputs: drop the dark PNGs first, then trim
      plan.md quotes.
   3. Run round 1 at `--max-usd` equal to the remaining budget (0.50 minus
      the estimates spent so far).
   4. Accept or rebut each P0, P1, and P2 finding yourself. `SendMessage`
      the writing agent to apply accepted text fixes, and resume the diagram
      agent to apply accepted visual fixes, re-lint, and re-render both
      themes with `diagram_render.rb` so round 2 sees the fixed PNGs before
      its estimate. Write `roast/round-N.response.json` (the cf:roast response
      shape) for every round run, an empty response list when it has no
      findings; `plan_check.rb` fails a round without it. Contested calls go to
      `AskUserQuestion`; under `--judge`, through the judge protocol in
      `reference/interview.md`, recorded as `Answered by: judge (roast)`.
   5. Round 2 runs only if
      `ruby ~/.claude/cf/bin/roast.rb decide --out-dir <plan_dir>/roast`
      says continue and the summed estimates, round 2's own included, stay at
      or under 0.50 USD. There is never a round 3.
   6. The writing agent appends `## Roast` to plan.md: rounds run, score per
      round and spend (summed estimates), each finding with its verdict
      (accepted, rebutted, or contested) and resolution, any open P0 or P1,
      and any skip reason.
   7. On a sensitive-term refusal (exit 1), scrub and retry once. Exit 4 (no
      key) or a second refusal records "roast skipped: <reason>" in
      `## Roast` and continues. Without Docker, roast the text only and
      record "visuals not rendered, text-only roast."

8. **Verify what landed.**

   ```bash
   ruby ~/.claude/cf/bin/plan_check.rb <plan_dir>
   ```

   It fails on a missing or empty file, a `goal.md` over 4000 characters, an
   AI-slop glyph, or a `workflow.js` that is missing its literal
   `export const meta = {` header, has no `phase()` call, or calls
   `Date.now()`, `Math.random()`, or `new Date()`. When the plan has a
   `diagrams/` directory or a `## Visuals` section, it also fails on a listed
   SVG that is missing, an SVG with a glyph, a home path, or no
   `data-diagram-type`/`data-chart-type`, and a `roast/round-N.json` without
   its `round-N.response.json`. Do not report success until it exits zero.

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
    which decisions the user's answers changed, how many visuals landed, and
    the roast rounds, scores, and spend. Stop here.

    Stack landing is the default for a multi-PR plan. When the plan has more
    than one PR phase, the handoff ends with "When the phases are open as PRs,
    run `/cf:sweep stack <plan_dir>`.", so cf:sweep stack mode lands the PRs
    strictly one at a time by merge mode. A single-PR plan omits the line.

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
- No Docker at 7a or 7b: lint with `--no-measure`, skip rendering, roast the
  text only, and record the gap in `## Visuals` and the report.
- No roast key (exit 4) or a second sensitive-term refusal: record "roast
  skipped: <reason>" in `## Roast` and continue.
