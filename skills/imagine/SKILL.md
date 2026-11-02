---
name: cf:imagine
group: workflow
description: Imagines 3 to 5 divergent options for the creative direction of any it (UI, brand, campaign, art, video), lets the human pick or cherry-pick elements across options, then runs 2 to 3 rounds of background critic review converging on one production-ready creative plan. Working files stay out of git; the outcome is one numbered record at docs/creative/NNNN-slug.md that cf:design folds into DESIGN.md. Free by default; --images and --roast are paid and opt-in.
---

# CF imagine

Diverge first, converge second. Options are cheap to write and expensive to un-pick later, so write several that really differ, let the human choose or combine, then attack the winner until it is production-ready. The "it" is anything with a creative direction: a UI, a brand, a campaign, an illustration style, a video.

A command skill: it runs only when invoked by name. It is free by default (text option briefs, free critic agents). `--images` and `--roast` spend money and are opt-in.

## Usage

`cf:imagine <it description or brief path> [--options 3..5] [--rounds 2..3] [--images [--max-usd N]] [--roast] [--area A] [--slug S]`

- `--options` defaults to 3, `--rounds` to 2. An out-of-range value is refused with a one-line message, never clamped.
- `--images` adds a cf:image moodboard per option, with a cost estimate first and a `--max-usd` ceiling.
- `--roast` runs paid cf:roast on the moodboards in the final round only. It requires `--images`; without it, refuse at the start, before any work.
- There is no config key. Flags are the only configuration.

## Inputs

Read, in this order:

1. The it, as described by the user or a brief path.
2. Any PRD, SOW, or brief paths the user names.
3. The root `DESIGN.md` and token files, if present.
4. Existing `docs/creative/*.md` records. Accepted ones constrain the new work; superseded ones are history only.

Decide two things and write them into `brief.md`:

- `ui: true|false`: is the it a user interface?
- `applies_to`: short tags (`ui`, `brand`, `campaign`, `video`, `art`, ...).

When `ui: true`, load cf:usability, cf:prototyping, and cf:fractal by name. For any other it, do not load them.

## Setup

```
ruby ~/.claude/cf/bin/imagine_paths.rb resolve --area <area> --slug <slug>
```

In this repo the script is `scripts/imagine_paths.rb`. It prints JSON with `dir`, `dir_tilde`, and `exists`. The working directory is `$CF_IMAGINE_ROOT` (default `~/.claude/cf/imagine`) `/<area>/<slug>/`, outside git. If `exists` is true, ask whether to resume or pick a new slug (away mode: new slug). Create the directory and write `brief.md` (the it, audience, constraints, inputs read, `ui`, `applies_to`) and `state.json`.

```
brief.md             the it, audience, constraints, inputs read
options/a.md..e.md   one option brief per option
moodboards/<opt>/    only with --images: cf:image outputs and contact sheet
picks.md             table: element | source option | reason
rounds/1.md..        merged critic findings and resolutions per round
draft.md             current creative plan, rewritten each round
state.json           { options, rounds_planned, rounds_run, images, roast, record_path }
.cache/              passed to image.rb --cache
```

## Diverge

Write N option briefs from `reference/option-template.md`.

- Options must differ on at least three axes: concept, palette or material, type or voice, composition, motion, format.
- Each option names what it is NOT.
- Run an originality check against `skills/design/reference/banned-defaults.md` (installed beside cf:design) before showing anything. A banned default survives only when the brief or DESIGN.md explicitly chooses it.
- Present compact text summaries: a name, one sentence of concept, and the axis values per option. Not the full briefs.

## Moodboards (only with --images)

1. Print the cf:image estimate for N boards at `medium` quality. Stop if it is above `--max-usd`, and offer to continue text-only.
2. Generate each board with cf:image (`image.rb`) using `--cache <dir>/.cache`, one per option, under `moodboards/<opt>/`.
3. Build the contact sheet through cf:design's moodboard path (inline HTML in browserless).
4. Never for UI screenshots. If `OPENAI_API_KEY` is missing, fall back to text-only and record it in `brief.md`.

## Decide

Ask with AskUserQuestion, recommendation first: pick one option, or cherry-pick. For a cherry-pick, ask per element axis which option supplies it. Write `picks.md` (element, source option, reason).

Away mode: take the recommended combination and log it in `picks.md`.

## Converge rounds

For round r in 1..R:

1. Write `draft.md`: the current creative plan, rewritten from the picks and the previous round.
2. Launch four background critic agents in parallel, each with its prompt from `reference/critic-lenses.md`: originality, brand fit, feasibility and production cost, audience. When `ui: true`, add cf:design's UI critics (usability, accessibility, simplicity).
3. Merge findings into `rounds/r.md`. Settle the uncontested ones yourself. Ask each contested one with AskUserQuestion, recommendation first.
4. Stop early when a round leaves nothing contested.

If a critic fails or times out, proceed with the remaining lenses and note the gap in `rounds/r.md`.

Final round with `--roast`: print the cf:roast estimate, stay within the ceiling, run cf:roast on the moodboards, and fold its accepted fixes into `draft.md`.

## Record

```
ruby ~/.claude/cf/bin/imagine_paths.rb next-record --repo .
```

It prints `{ "number": "0003", "dir": "docs/creative" }`. On duplicate numbers it exits 1: stop and ask the human to renumber (away mode: record the blocker and stop before writing).

Write `docs/creative/NNNN-<slug>.md` from `reference/record-template.md` with `status: accepted`.

- Every line in Production plan carries one tag: `[evidence]`, `[assumption]`, or `[proposal]`.
- The record stands alone without the working directory. Describe moodboards in words. Commit no images.
- Superseding an earlier record: write a new number and flip the old record's status to `superseded by NNNN`.
- Not in a git repo: write under the cwd `docs/creative/` anyway and say it is uncommitted.

This skill does not commit or push beyond what the session merge mode already allows.

## Classify and hand off

Compare the final plan to the existing root `DESIGN.md`. With no DESIGN.md, count the outcome as `promote` only when the plan defines reusable system-level patterns.

- Consistent with established patterns, or a local one-off: `design_md: none`. The Handoff section reads "no DESIGN.md change". Print no cf:design command.
- A major divergence from DESIGN.md, or a new reusable system-level pattern: `design_md: promote`. Print the exact next command, for example `cf:design docs/creative/0003-launch-brand.md`.

Always write `design_md_reason:` as one line. In away mode choose `none` unless the divergence is explicit.

cf:imagine never edits DESIGN.md and never chains into cf:design. cf:design is the only writer of DESIGN.md.

## Away mode

No questions. Each contested call goes under `## Open questions` in the record with the options and the recommended default; the draft continues on that default. Cherry-pick takes the recommended combination.

## Failure modes

- Out-of-range `--options` or `--rounds`: refuse with usage.
- `--roast` without `--images`: refuse at the start.
- Estimate above `--max-usd`: stop before any paid call; offer text-only.
- Missing OpenAI key with `--images`: text-only, noted in `brief.md`.
- Duplicate record numbers: see Record.
- Working directory deleted later: nothing breaks, the record is self-contained.

## Done when

- `docs/creative/NNNN-<slug>.md` exists with `status: accepted`, `design_md`, and `design_md_reason`.
- Every paid call was preceded by a shown estimate and stayed under the ceiling.
- The report gives the record path, the chosen option or picks, what the critics changed, any open questions, and the Handoff line (the cf:design command, or "no DESIGN.md change").
