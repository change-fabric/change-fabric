---
name: cf:prototyping
group: workflow
description: Prototyping methodology reference loaded by name by cf:design, cf:prototype, and cf:walkthrough. Frames each mock around the design question it answers (Houde and Hill role, look and feel, implementation), picks the lowest fidelity that answers it, writes testable hypotheses, and supplies own-words observable checks for the ten usability heuristics and a design-time WCAG 2.2 subset.
---

# Prototyping

Source: Stephanie Houde and Charles Hill, "What do Prototypes Prototype?" (1997); Jakob Nielsen, ten usability heuristics (1994), via cf:usability; W3C, WCAG 2.2 (2023), https://www.w3.org/TR/WCAG22/

This is a reference skill. cf:design, cf:prototype, and cf:walkthrough load it by name before they author or evaluate anything. It has no auto trigger.

## The question each prototype answers

A prototype is a question made visible. Before authoring a mock, write the one question it exists to answer, in a sentence a stakeholder could say yes or no to. A mock with no question is decoration; drop it or find its question.

Houde and Hill place every prototype in a triangle of three dimensions:

| Dimension | Asks | Example question |
|---|---|---|
| Role | What does this do in the user's life? | Does a shift lead see who is late without opening a report? |
| Look and feel | What is it like to see, touch, and use? | Does the dense table still read as calm at a glance? |
| Implementation | How does it actually work? | Can the sync finish under two seconds on a slow link? |

Integration prototypes sit at the center: they combine all three and approximate the final artifact.

## Fidelity decision framework

1. List the open questions from the PRD, SOW, brief, or the existing app.
2. Classify each by dimension: role, look and feel, or implementation.
3. Pick the riskiest one: the question whose wrong answer costs the most rework.
4. Choose the lowest fidelity that answers it. A role question often needs only a storyboard; a look and feel question needs tokens, real type, and real density; neither needs working code.
5. Audience is the second axis. A team member reads a rough frame; an executive or customer needs finished visuals to judge role at all, so raise visual fidelity for them without adding implementation.
6. An implementation or integration question is out of scope for a mock. Record it as a finding: "recommend a code spike" naming the question, and move on.

Favor:

- One question per screen state, written down before the HTML.
- The cheapest artifact that would change a decision.
- Real content density and fictional but plausible data over lorem ipsum.

Avoid:

- Raising fidelity to look finished when the question is role.
- Faking an implementation answer (latency, sync, scale) with a mock.
- Mocks that answer no question on the list.

## What a mock walkthrough is

A mock walkthrough is a role plus look and feel prototype. It is never an implementation or integration prototype, however polished the video is. Client-side state in mocks (localStorage, an in-memory store seeded from fictional records) serves realism of role and feel, not proof of implementation.

State this scope in findings and in `walkthrough/<slug>/ASSUMPTIONS.md`. Never state it in the video, the frames, or the narration: the video presents as the shipped product.

## Hypotheses

Every prototype carries testable hypotheses. Storyboard scenes cite them by id.

```
H-NN
Statement: <what we believe is true about the user and the design>
Dimension: role | look and feel
Refuted if: <the observable evidence that would prove it wrong>
```

Example:

```
H-03
Statement: Managers approve a pending request from the list without opening it.
Dimension: role
Refuted if: the approve control is not visible on the list row at 1280px, or the
recorded scene needs a detail view to finish the approval.
```

Rules:

- Number hypotheses `H-01` upward within a walkthrough; never reuse an id.
- A refutation names something a viewer or a check can see on a frame or in a recorded sequence.
- An implementation hypothesis is not written here; it becomes a code spike finding.

## Evaluation output format

Every check, heuristic or WCAG, reports exactly one of:

| Result | Meaning |
|---|---|
| `pass` | The evidence on the frames supports the check |
| `issue (severity 0-4)` | The check fails; severity uses the cf:usability scale (0 not a problem, 1 cosmetic, 2 minor, 3 major, 4 blocks the task) |
| `not evaluable` | The state or evidence needed is absent from the mock |

Each result cites the screen, scene, or frame it rests on. Fix the highest severity first. A `not evaluable` is not a failure and is not a pass; list it so a reader knows what was never seen.

## Heuristic evaluation

Load cf:usability by name and apply its rubric. This skill carries no heuristic checklist of its own; cf:usability is the single home for the ten heuristics. Report each finding in the output format above, citing the heuristic id cf:usability uses, and let scenes cite those ids in `heuristics_shown`.

## WCAG policy

- Target WCAG 2.2. Level AA is required; level AAA is advisory and never blocks.
- Error, focus, and 320px states are optional in a mock. When a state is absent, the criteria that need it are `not evaluable`, not failed.
- The criteria split three ways by what a mock can show. See `reference/wcag-design-time.md`:
  - checkable at design time from tokens and declared styles,
  - indicative on rendered frames,
  - not checkable until real code exists, deferred to cf:a11y.
- cf:a11y axe-core may run against the mock HTML inside the pinned browserless container as an indicative check. Its result is never a certification and never stands in for an audit of the real product.

## Handoff to the calling skill

The calling skill (cf:design, cf:prototype, or cf:walkthrough) receives:

- the question list with dimension and riskiest question marked,
- the chosen fidelity and audience,
- hypotheses `H-NN`,
- code spike findings for implementation questions,
- heuristic and WCAG results in the output format above.

It records invented features, fictional data, and scope notes in ASSUMPTIONS.md and keeps requirement and hypothesis provenance in the storyboard.
