# State diagram

A state diagram shows the conditions one thing can be in and the events that move it between them. The reader should be able to answer: from here, where can it go next, and what makes it go there?

## When to use

- One entity with a lifecycle: an order, a document, a job, a connection, a subscription.
- The set of states is small and named, and the interesting part is which moves are allowed.
- Some transitions loop back (retry, reopen, send back) or stay put (a refresh that keeps the state).
- A capped retry needs the transition taken when the cap is reached, and the events leaving one state must not overlap.

## When not to use

- The steps are actions done by someone, in order, with no notion of the thing resting in a state: use `flow`.
- Several actors trade messages over time: use `sequence`.
- The question is who owns each step: use `swimlane`.
- More than about 8 states, or transitions that cross every other one: split the lifecycle into sub-machines, one diagram each.

## Layout skeleton

- Read left to right along the happy path. The start state sits at the far left, the terminal state at the far right, all on one row when they fit.
- Forward transitions are straight horizontal edges between neighbors on that row.
- Back-edges (a later state returning to an earlier one) go below the row, as one curve that leaves the bottom of the source and lands on the bottom of the target.
- Self-loops (an event that keeps the state) sit above the box, as a small curve leaving and re-entering the top edge.
- Side states that branch off the happy path (failed, cancelled) go on a second row under the state they leave from, joined by a vertical edge.
- States are rounded boxes (`rx` of half the height) so they read as conditions, not as steps.

## Semantic classes

- `.node` with `data-id` per state, its `<rect>` with full rounding, and a `.label` naming the state as an adjective or past participle (Draft, In review, Published).
- `.edge` for every transition. Use `#arrow` on happy-path transitions and `#arrow-soft` on back-edges and self-loops.
- `.note` for the event that triggers a transition, set in 12px next to its edge, at least 4px clear of it.
- `--accent` on at most one state, usually the one the reader is asking about.

## Connector rule

Orthogonal by default: `M`, `H`, `V`, and axis-aligned `L`. State is the one type where `C` and `Q` curves are allowed, and only for back-edges and self-loops. Every transition is directed and carries a marker. Each endpoint touches its state box within 2px.

## Multi-line labels

When a label would push its box past the width the layout allows, wrap it onto two lines with one `<tspan>` per line, the `x` repeated on each, and `dy="16.8"` for 14px text. Grow the box to 64 tall and set the first baseline at box center minus 3.5:

```xml
<text class="label" x="128" y="76.5" font-size="14" text-anchor="middle"><tspan x="128">Reserve</tspan><tspan x="128" dy="16.8">inventory</tspan></text>
```

See "Multi-line labels" in `grammar.md` for the arithmetic.

## Lint allowances

- `connector-geometry` accepts cubic and quadratic commands here (`TYPE_RULES["state"]` has `curves: true`). Other types reject them.
- `arrow-marker` still requires a resolving marker on every edge, curved or not.
- Everything else in `grammar.md` applies unchanged: grid, box height, baseline, padding, spacing, margin, overlap, and caps.

## Worked example

A document lifecycle with one back-edge. The curve's lowest point is at y=126, and the event label below it starts near y=139, so the label clears the edge.

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 672 192" width="672" height="192" role="img" aria-labelledby="t d" data-diagram-type="state">
  <title id="t">Document review states</title>
  <desc id="d">A document moves from Draft to In review to Published. A reviewer can send it back from In review to Draft with changes requested.</desc>
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
  <rect class="bg" x="0" y="0" width="672" height="192" fill="#F5F5F5"/>
<g class="node" data-id="draft">
    <rect x="48" y="48" width="160" height="48" rx="24"/>
    <text class="label" x="128.0" y="76.9" font-size="14" text-anchor="middle">Draft</text>
  </g>
  <g class="node" data-id="review">
    <rect x="256" y="48" width="160" height="48" rx="24"/>
    <text class="label" x="336.0" y="76.9" font-size="14" text-anchor="middle">In review</text>
  </g>
  <g class="node" data-id="published">
    <rect x="464" y="48" width="160" height="48" rx="24"/>
    <text class="label" x="544.0" y="76.9" font-size="14" text-anchor="middle">Published</text>
  </g>
  <path class="edge" data-from="draft" data-to="review" d="M208 72 H256" marker-end="url(#arrow)"/>
  <path class="edge" data-from="review" data-to="published" d="M416 72 H464" marker-end="url(#arrow)"/>
  <path class="edge" data-from="review" data-to="draft" d="M336 96 C336 136 128 136 128 96" marker-end="url(#arrow-soft)"/>
  <text class="note" x="232.0" y="148" font-size="12" text-anchor="middle">changes requested</text>
</svg>
```
