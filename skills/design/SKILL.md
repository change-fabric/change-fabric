---
name: cf:design
group: workflow
description: Adversarial, opinionated design-system command. Reads a PRD, SOW, brief, existing DESIGN.md, token files, brand assets, or a running app, drafts an opinionated DESIGN.md plus a minimal tokens.css, sends four background critic agents (usability via cf:usability, accessibility, brand, simplicity) at both the existing system and the draft, grills the user with AskUserQuestion on contested calls for up to three rounds, then rewrites DESIGN.md wholesale. Invoked directly, and loaded by cf:walkthrough when a PRD has no design system yet.
---

# CF design

Source: Jakob Nielsen, ten usability heuristics (1994), via cf:usability; W3C, WCAG 2.2 (2023), https://www.w3.org/TR/WCAG22/; the minimal color system notes, via cf:color.

Load cf:prototyping and cf:usability by name before anything else. cf:prototyping supplies the design questions and `reference/wcag-design-time.md`; cf:usability supplies the heuristics. This skill carries no heuristic checklist of its own.

## Stance

Be opinionated and adversarial. An existing design system is evidence, not a constraint: do not assume it is good. The output is a real, bona fide update to DESIGN.md that keeps only what review judged good and replaces the rest.

Never:

- add a `## Proposed` section or any "proposed changes" appendix
- write a sibling file (`DESIGN.proposed.md`, `DESIGN-v2.md`, a review report)
- stop at a report or a list of suggestions

The deliverable is always the rewritten `DESIGN.md` and `tokens.css` at the target repo root.

## Inputs

Any of, in priority order:

1. PRD, SOW, or brief paths named by the user.
2. An existing `DESIGN.md` and token files (`tokens.css`, a Tailwind theme, CSS custom properties).
3. Brand assets: logos, brand guidelines, existing marketing pages.
4. A running app URL. A screenshot via browserless is optional evidence, taken only through `ChangeDocker.with_browserless` and `BrowserlessJs`; never a host browser.

With none of these, ask the user for a brief before drafting.

## Process

Each round runs the same five steps. At most three rounds.

1. Read evidence. Record each source path and the anchor (heading or line) you will cite.
2. Draft. Write an opinionated DESIGN.md in memory from `reference/design-md-template.md`, plus a draft tokens.css. On round two and later, draft from the previous round's revision.
3. Critique. Spawn four background critic agents in parallel, each given the existing system (if any), the draft, and the evidence paths:
   - usability: loads cf:usability by name and inspects the draft against each heuristic it names
   - accessibility: checks against cf:prototyping's `reference/wcag-design-time.md`; AA is required, AAA advisory
   - brand: does the system say what the product is, and does it honor the brand assets; also checks the draft against `reference/banned-defaults.md` (dated generic AI-look defaults)
   - simplicity: what can be deleted; every token, font, and component must earn its place

   Each critic attacks both the existing system and the draft and returns findings, each with a verdict (keep, change, cut) and a reason.
4. Consolidate. Merge critic findings. Settle uncontested ones yourself. Collect the contested calls: critics disagree, or a call trades one value against another, or the evidence is silent.
5. Grill. Ask the user about each contested call with AskUserQuestion, offering concrete options with your recommendation first. Revise the draft from the answers.

Stop early when a round produces no contested calls. After the last round, write.

## Minimal token set

- About four authored colors (two conceptual colors, two variants each), plus an optional `--error`.
- Role tokens: `--bg`, `--surface`, `--border`, `--text`, `--heading`, `--muted`, `--accent`, `--link`, `--btn`, `--btn-text`, plus `-text` aliases where a role needs a paired foreground.
- Three font stacks: body, heading, mono.
- One spacing scale, one radius, one focus ring, one motion duration.
- Minimum target size 24px.
- Light and dark themes by role reassignment among the same authored colors, never by new literals.

Run cf:color's checker on the draft tokens:

```
ruby ~/.claude/cf/bin/color_check.rb --tokens tokens.css --json
```

AA failures block the write. AAA misses are advisory. Paste the contrast pairs into DESIGN.md's Accessibility commitments section as checker output in a fenced block, not as hand-computed numbers.

## Provenance

Every content line from Principles through Do and do not carries one inline tag:

- `[evidence: <src>#<anchor>]` for a call drawn from an input
- `[assumption]` for a call the evidence does not settle
- `[proposal]` for an opinion this run is bringing to bear

Headings, table header rows, fenced blocks, and blank lines are exempt.

## Moodboards (optional)

Only when the user wants look-and-feel exploration. Generate with cf:image (`image.rb`, gpt-image-2) at `medium` quality, cached by content hash, never committed. Print the cost estimate before any paid call. Render contact sheets of moodboard images and token swatches as inline HTML in browserless via `ChangeDocker.with_browserless` and `BrowserlessJs.inline_html_js`.

## Roast (optional)

Only when the user wants the draft's mock screens stress-tested. Load cf:roast by name: it is paid, runs a capped multi-round loop against an OpenAI vision critic, and logs each round to `roast/`. Never auto-run.

## Output and lint

Write `DESIGN.md` and `tokens.css` at the target repo root, then:

```
ruby ~/.claude/cf/bin/design_tokens.rb lint DESIGN.md tokens.css
```

The lint checks required sections, that every declaration in a css fence appears verbatim in tokens.css, and provenance tags. Add `--contrast` to fold color_check AA failures in. Fix and rerun until it prints `clean`. cf:design does not finish until it does.

Report to the user: what was kept from the existing system and why, what was cut, the contested calls and their answers, and the lint result.
