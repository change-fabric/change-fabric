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
- Every edge is directed and ends in a marker. Use `#arrow` on the happy path and `#arrow-muted` on failure or fallback branches, so the eye follows the main row first.
- Main-row edges run from the right side of one box to the left side of the next, at the box center line. Branch edges leave the bottom center and enter the top center of the step below.
- A branch condition is a `.note` placed in the gap beside its edge, at least 4px clear of the line. On a vertical edge give the note `text-anchor="start"` and an `x` a few pixels right of the line.
- A loop back to an earlier step routes below the rows with two bends, never through a box. If loops dominate, the subject is a `state` diagram.

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
    svg { --bg: #FBFBFA; --surface: #FFFFFF; --ink: #1F2328; --muted: #5B6470; --line: #8A939E; --accent: #2F5D8A; --accent-2: #8A5A2F; }
    @media (prefers-color-scheme: dark) {
      svg { --bg: #16181B; --surface: #1E2125; --ink: #E8EAED; --muted: #A3ABB5; --line: #6E7781; --accent: #7FA8D1; --accent-2: #D1A37F; }
    }
    .bg { fill: var(--bg); }
    .node rect { fill: var(--surface); stroke: var(--line); stroke-width: 1.5; }
    .label { fill: var(--ink); font-family: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", "Noto Sans CJK SC", "Noto Sans CJK JP", sans-serif; }
    .edge { fill: none; stroke: var(--line); stroke-width: 1.5; }
    .group rect { fill: none; stroke: var(--muted); stroke-dasharray: 4 4; }
    .note { fill: var(--muted); font-family: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", "Noto Sans CJK SC", "Noto Sans CJK JP", sans-serif; }
  </style>
  <defs>
    <marker id="arrow" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 Z" fill="#8A939E"/></marker>
    <marker id="arrow-muted" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 Z" fill="#5B6470"/></marker>
  </defs>
  <rect class="bg" x="0" y="0" width="672" height="264" fill="#FBFBFA"/>
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
  <path class="edge" data-from="validate" data-to="error" d="M336 96 V168" marker-end="url(#arrow-muted)"/>
  <text id="valid-note" class="note" x="440" y="62" font-size="12" text-anchor="middle">valid</text>
  <text id="invalid-note" class="note" x="344" y="136" text-anchor="start" font-size="12">invalid</text>
</svg>
```
