# Flow diagrams

Type: `data-diagram-type="flow"`. Read `grammar.md` first; this file adds only what is specific to flows.

## When to use

A flow shows the steps a single piece of work passes through, in order, and the points where it branches. Use it for request handling, checkout or signup steps, a build pipeline, or any "this, then this, unless that" process where the reader cares about sequence and outcome.

## When not to

- Several actors handing work to each other over time: use `sequence` (who calls whom) or `swimlane` (who owns which step).
- A thing that sits in one of a few modes and moves between them, often returning: use `state`. A flow has a start and an end; a state machine loops.
- Static parts and how they connect: use `architecture`.
- Dated events: use `timeline`.

## Layout skeleton

- Reading direction is left to right along one main row, the happy path. Every step on that row shares one `y`.
- Branches leave the main row downward and form a second row below it, aligned to the column of the step they branch from. Keep branches to one or two; more means the flow wants splitting.
- Columns sit on a fixed pitch: a 160 wide box plus a 48 gap is a 208 pitch, which keeps every `x` on the 8px grid and leaves room for an edge label in the gap.
- Rows sit on a fixed pitch too: a 48 tall box plus a 72 gap leaves room for a vertical edge and its label.
- One start step at the far left and one or more end steps. Mark the outcome the reader cares about most with `--accent`, and only that one.

## Classes

- `.node` for every step, each a `<rect>` with a 14px `.label`.
- `.edge` for every connector.
- `.note` (12px) for edge labels such as a branch condition.
- `.group` only to box a sub-process that a second diagram expands; usually omit it.

## Connectors

- Orthogonal only: `M`, `H`, `V`, and axis-aligned `L`. No `C` or `Q`.
- Every edge is directed and ends in a marker. Use `#arrow` on the happy path and `#arrow-soft` on failure or fallback branches, so the eye follows the main row first.
- Main-row edges run from the right side of one box to the left side of the next, at the box center line. Branch edges leave the bottom center and enter the top center of the step below.
- A branch condition is a `.note` placed in the gap beside its edge, at least 4px clear of the line. On a vertical edge give the note `text-anchor="start"` and an `x` a few pixels right of the line.
- A loop back to an earlier step routes below the rows with two bends, never through a box. If loops dominate, the subject is a `state` diagram.
- The conditions on the edges leaving one step are mutually exclusive and together cover every outcome, so a reader never has to work out which branch fires. Write each one as its full guard ("findings, under 3 fixes", "findings after 3 fixes"), not a bare outcome ("findings") with the limit parked in a separate note.
- A bounded loop (retries, fix rounds, a polling cap) draws its exit: an edge from the deciding step, guarded by the exhausted bound, to a terminal step that names what happens then (report, fail, escalate). A loop with only an "up to N" note reads as unbounded.
- A bounded loop names its unit. Say what one pass is (one fix plus one re-lint) in a callout or the guard itself, and word the guards around the count so exactly one is true on every pass: UNDER 3 FIXES and AFTER 3 FIXES, never FINDINGS beside 3 ROUNDS USED.

## Multi-line labels

When a label would push its box past the width the layout allows, wrap it onto two lines with one `<tspan>` per line, the `x` repeated on each, and `dy="16.8"` for 14px text. Grow the box to 64 tall and set the first baseline at box center minus 3.5:

```xml
<text class="label" x="128" y="76.5" font-size="14" text-anchor="middle"><tspan x="128">Reserve</tspan><tspan x="128" dy="16.8">inventory</tspan></text>
```

See "Multi-line labels" in `grammar.md` for the arithmetic.

## Lint allowances

| rule | flow |
|---|---|
| connectors | orthogonal |
| curves | no |
| markers | required on every edge |

All other checks apply as written in `grammar.md`.

## Worked example

An order is submitted and validated. A valid order is charged; an invalid one shows an error. The same SVG is `test/fixtures/diagram/clean_flow.svg`.

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 672 264" width="672" height="264" role="img" aria-labelledby="t d" data-diagram-type="flow">
  <title id="t">Order submission flow</title>
  <desc id="d">A submitted order is validated. Valid orders are charged; invalid ones show an error to the customer.</desc>
  <style>
    svg { --bg: #F5F5F5; --surface: #FFFFFF; --ink: #2D3142; --muted: #4F5D75; --soft: #5A6580; --line: #4F5D75; --rule: #D9DADD; --accent: #B5401C; --accent-tint: #F2E9E6; --link: #2E5AA8; }
    @media (prefers-color-scheme: dark) {
      svg { --bg: #2D3142; --surface: #2D3142; --ink: #F5F5F5; --muted: #BFC0C0; --soft: #A3ACC0; --line: #A3ACC0; --rule: #45495A; --accent: #F08A59; --accent-tint: #3D3844; --link: #7FA9E6; }
    }
    .bg { fill: var(--bg); }
    .node rect { fill: var(--surface); stroke: var(--ink); stroke-width: 1; }
    .label { fill: var(--ink); font-weight: 600; font-family: Geist, Inter, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", "Noto Sans CJK SC", "Noto Sans CJK JP", sans-serif; }
    .edge { fill: none; stroke: var(--line); stroke-width: 1.2; }
    .group rect { fill: none; stroke: var(--muted); stroke-dasharray: 4 4; }
    .note { fill: var(--muted); font-family: Geist, Inter, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", "Noto Sans CJK SC", "Noto Sans CJK JP", sans-serif; }
  </style>
  <defs>
    <marker id="arrow" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 Z" fill="#4F5D75"/></marker>
    <marker id="arrow-soft" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 Z" fill="#5A6580"/></marker>
  </defs>
  <rect class="bg" x="0" y="0" width="672" height="264" fill="#F5F5F5"/>
  <g class="node" data-id="submit">
    <rect x="48" y="48" width="160" height="48" rx="6"/>
    <text id="submit-label" class="label" x="128" y="76.9" font-size="14" text-anchor="middle">Submit order</text>
  </g>
  <g class="node" data-id="validate">
    <rect x="256" y="48" width="160" height="48" rx="6"/>
    <text id="validate-label" class="label" x="336" y="76.9" font-size="14" text-anchor="middle">Validate</text>
  </g>
  <g class="node" data-id="charge">
    <rect x="464" y="48" width="160" height="48" rx="6"/>
    <text id="charge-label" class="label" x="544" y="76.9" font-size="14" text-anchor="middle">Charge card</text>
  </g>
  <g class="node" data-id="error">
    <rect x="256" y="168" width="160" height="48" rx="6"/>
    <text id="error-label" class="label" x="336" y="196.9" font-size="14" text-anchor="middle">Show error</text>
  </g>
  <path class="edge" data-from="submit" data-to="validate" d="M208 72 H256" marker-end="url(#arrow)"/>
  <path class="edge" data-from="validate" data-to="charge" d="M416 72 H464" marker-end="url(#arrow)"/>
  <path class="edge" data-from="validate" data-to="error" d="M336 96 V168" marker-end="url(#arrow-soft)"/>
  <text id="valid-note" class="note" x="440" y="62" font-size="12" text-anchor="middle">valid</text>
  <text id="invalid-note" class="note" x="344" y="136" text-anchor="start" font-size="12">invalid</text>
</svg>
```
