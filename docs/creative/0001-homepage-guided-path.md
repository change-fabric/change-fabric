---
status: accepted
date: 2026-11-16
applies_to: [ui, brand]
working_dir: ~/.claude/cf/imagine/change-fabric/homepage-guided-path
options: 4
rounds: 0
design_md: none
design_md_reason: The direction stays inside site/DESIGN.md's palette, type and row rules; no system-level pattern is added.
---
# 0001 - The homepage is a guided path with an implicit four-part story

## Status

Accepted. Shipped as the homepage redesign; the hero's journey walkthrough (walkthrough/site-hero-journey) follows the same order.

## Context

The changefabric.org homepage opened on the release gate and a CHANGE.md example. The new page is for a newcomer moving into engineering who already asks a coding agent for code but has never configured one, with an engineer arriving for the gate as a second reader. Constraints came from site/DESIGN.md (cream, plum, lilac, sage only; quiet editorial; hairline rows, no cards, gradients or glows; serif headings, sans body, mono identifiers), from provenance rules (credit, not endorsement, and no claim that every rubric is book-grounded) and from the install path (three commands, open your agent, watch a rubric apply). Inputs read: the old Home.tsx, site/DESIGN.md, site/src/styles.css, the toolkit map, the README install section and the rubric source lines.

## Options considered

A, Three questions: the newcomer's questions (What is it, Is it for me, How do I start) as numbered sections with a layer diagram. It is not a centred hero with feature cards and not an accordion.

B, Standing on shoulders: provenance leads, with a ledger of rubrics and the works they draw on as the centrepiece. It is not a logo wall or an endorsement strip.

C, Hero's journey: four beats (the call, the mentor, the trial, the return) with a chapter rail and timestamps matched to a planned walkthrough. It is not hype and not a stepper.

D, Hero's journey with three answers inside: C's order kept implicit, each section headed by the plain question it answers, with A's answers as the substance. It is not a story told out loud: no chapter labels, numbers or timestamps.

## Decision

D. The order (call, mentor, trial, return) comes from C and stays behind the scenes; the section headings are "Is it for me?", "What is it?", "Before it merges" and "Start building". From A: the who-you-are rows, the layer diagram with rubric, command and hook rows, the CHANGE.md summary with five lanes and a failure label each, and the three install commands with the first win. From A and C: the provenance credit line (Metz, Fowler, Nielsen, Houde and Hill) and the harness list. Revision 1 shortened the hero action to "Start Building", rewrote the hero copy as a plain description, and removed every chapter rail, index, timestamp and arc prefix. No critic rounds ran; the user's revision is the only change after the pick.

## Rejected

- B: the user did not pick it; a newcomer may not know Metz or Fowler, so a bibliography first can read as name-dropping.
- C's chapter rail, index and timestamps: they commit the video edit to fixed chapters and make the metaphor visible, which an engineer arriving for the gate may find precious.
- A's numerals: the order carries the story, so nothing on the page numbers it.

## Production plan

- Palette: plum and cream grounds, lilac only on the hero and install actions and the top layer of the diagram. [evidence]
- Type: serif question headings, sans body, mono for commands and skill names. [evidence]
- Voice: second person, plain answers, quiet editorial tone; no arc labels on screen. [evidence]
- Composition: one column at the 760px measure; "What is it?" widens to 1040px so the diagram sits beside its rows. [evidence]
- Motion: none on the page; the hero action jumps to the install section. [evidence]
- Format: one scroll page with a click-to-load walkthrough poster under the hero. [evidence]
- The walkthrough follows the same order, opening on the problem from the hero copy and closing on "Start Building" plus the install line. [proposal]

## Consequences

Easier: the page and the walkthrough share one structure, and each newcomer question has one place. Harder: the gate depth sits lower, so an engineer scrolls further for CHANGE.md. Revisit the poster title when the walkthrough's real length is known.

## Handoff

no DESIGN.md change
