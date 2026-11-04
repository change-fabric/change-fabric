---
name: cf:brainstorm
group: workflow
description: Divergent step that runs before cf:plan and feeds it. Frames the problem in at most five sentences, launches four background Opus agents in one message to generate options from three fixed lenses (user-value, simplest-thing, risk-and-ops) plus one topic lens chosen at framing, clusters the options into named concepts, culls a shortlist with one cf:roast doc round under a 0.5 USD cap, and lets the user pick with AskUserQuestion. Lands brainstorm.md in the plan dir and prints a paste-ready cf:plan line with --seed. It never writes plan.md, goal.md, or workflow.js and never invokes cf:plan itself.
---

# CF Brainstorm

Source: own procedure. The parallel fixed-lens fan-out is borrowed from cf:design steps 3 and 4, the question-first framing from cf:prototype, and the plain hand-placed clarity ethos from cf:diagram (which is not invoked).

Trigger: `/cf:brainstorm <problem>` (optionally `--area <a>`, `--slug <s>`).

Question: before anyone plans, have several genuinely different directions been put on the table, and has the user, not the agent, picked the one to plan?

## What it produces

- `<plan_dir>/brainstorm.md`: framing, lenses used, every concept with its source lenses, the roast verdict, the chosen concept, the shortlist and why the rest lost, the seeded goal, and the handoff line.
- `<plan_dir>/brainstorm-comparison.md`: the shortlist comparison doc cf:roast reviews.
- `<plan_dir>/roast/`: the roast round log, when the roast ran.

`<plan_dir>` is `<plans_root>/<area>/<slug>`, the same directory cf:plan will use for that slug. When cf:plan later runs with `--seed` pointing at this brainstorm.md, it extends that directory in place.

## Reference files

- `reference/lens-prompt.md`: the prompt each generator agent receives.
- `reference/lenses.md`: the three fixed lens briefs and how to choose the topic lens.
- `reference/comparison-doc.md`: template for the shortlist comparison doc.
- `reference/brainstorm-template.md`: template for the landed brainstorm.md.

## Procedure

1. **Resolve location.** Pick a short kebab-case slug from the problem unless `--slug` is given. Run:

   ```
   ruby ~/.claude/cf/bin/plan_paths.rb resolve --slug <slug> [--area <area>]
   ruby ~/.claude/cf/bin/plan_paths.rb mkdir --area <area> --slug <slug>
   ```

   Keep `plan_dir` and its `_tilde` form. If `brainstorm.md` already exists there, AskUserQuestion: overwrite, or stop. If the area cannot be resolved, ask for `--area`.

2. **Frame.** Restate the problem in at most five sentences: who it is for, what hurts, what success looks like, and the hard constraints. Read `reference/lenses.md` and pick a topic lens. Ask one AskUserQuestion that confirms the framing and offers two or three topic lens candidates, the recommended one first. Use the answer; do not ask again.

3. **Diverge.** Render `reference/lens-prompt.md` once per lens (`{{framing}}`, `{{lens_name}}`, `{{lens_brief}}`). Launch four background Opus agents with the Agent tool, all four in a single message so they run in parallel: user-value, simplest-thing, risk-and-ops, and the topic lens. They are read-only researchers: they may read the repo for grounding but write nothing. Never send them as separate messages.

4. **Cluster.** When all four return, merge their options into three to six named concepts. Each concept records which lenses produced it; a concept several lenses reached independently is a signal worth saying out loud. Drop exact duplicates and keep a short "also considered" list for options that did not become concepts.

5. **Shortlist.** Pick two to four concepts for the cull and state in one line why each made it.

6. **Cull.** Write `<plan_dir>/brainstorm-comparison.md` from `reference/comparison-doc.md`. Keep it generic: no client or customer names, since roast runs a sensitive-terms scan. Write `<plan_dir>/brainstorm-brief.md` with the framing from step 2 and the ask: pick the one concept to plan and name the fatal flaw in each other. roast requires `--brief` on every call, the estimate included. Then:

   ```
   ruby ~/.claude/cf/bin/roast.rb --brief <plan_dir>/brainstorm-brief.md \
     --text <plan_dir>/brainstorm-comparison.md --kind doc \
     --audience "the engineer who will plan this" --purpose "pick one concept to plan" \
     --out-dir <plan_dir>/roast --estimate-only
   ```

   Show the `roast estimate:` line. Then run the same command once without `--estimate-only` and with `--max-usd 0.5`. One round only, no regenerate loop. If the estimate exceeds 0.5 USD, shorten the doc; never raise the cap. If the sensitive-terms scan refuses, scrub the doc and retry once. If roast cannot run (missing key, refusal after the retry), say so in one line and continue to step 7 without a verdict.

7. **Pick.** AskUserQuestion with the shortlisted concepts as options, the roast's leading concept first and marked recommended, each option carrying its one-line tradeoff. Ask a follow-up only for a contested call the roast raised. Under away mode take the recommended concept and report the assumption.

8. **Land.** Write `<plan_dir>/brainstorm.md` from `reference/brainstorm-template.md`. Write the seeded goal as one or two sentences naming the chosen concept. Record a ctx pointer `brainstorm-<slug>` (class active) through cf:ctx pointing at the brainstorm.md tilde path. Print the handoff line, fenced, paste-ready. cf:plan takes its slug from the seed's parent directory, so the plan lands beside brainstorm.md even when the seeded goal or a custom `--slug` would derive a different one:

   ```
   /cf:plan <seeded goal> --area <area> --seed <tilde path to brainstorm.md>
   ```

## Rules

- cf:brainstorm never writes plan.md, goal.md, or workflow.js and never invokes cf:plan.
- At most four generator agents, one per lens, in one message.
- One divergent pass and one cull. No second round.
- The roast never spends more than 0.5 USD.
- No AI-slop glyphs in brainstorm.md or the comparison doc.

## Failure modes

- Agents return overlapping options: that is clustering's job; do not re-launch.
- An agent fails: cluster from the three that returned and say which lens is missing.
- Roast unavailable: land without a verdict and note it in brainstorm.md.
- The user rejects every shortlisted concept: ask what was missing, record it in brainstorm.md, and stop without a handoff line.
