# Swimlane diagram

A swimlane diagram is a flow split into horizontal bands, one per owner. The reader should be able to answer: who does this step, and where does the work change hands?

## When to use

- A process that passes between people, teams, or systems, and the handoffs are the point.
- Two to five owners, each with at least one step.
- Accountability questions: which team is waiting on which, where a request stalls.

## When not to use

- One owner does every step: use `flow`.
- The owners trade messages and the timing of each reply matters: use `sequence`.
- The question is how components are wired, not who acts: use `architecture`.
- More than five lanes or about twelve steps: split the process at a handoff and draw two diagrams.

## Layout skeleton

- Lanes are full-width horizontal bands stacked top to bottom, all the same width, at least 24px apart.
- The owner name sits at the left end of its lane, in a fixed label column about 104px wide, so every lane label lines up.
- Time reads left to right. A step that happens later sits further right than every step before it, whatever lane it is in.
- Put the lane that starts the process on top. Order the rest by when they first act.
- Each step is a box inside exactly one lane, vertically centered in it.

## Semantic classes

- `.group` with `data-id` per lane, wrapping its dashed `<rect>`, its `.note` lane label, and the `.node` steps that belong to it.
- `.node` with `data-id` per step and a `.label` phrased as a verb (Submit order, Pick items).
- `.edge` for every connector, with `#arrow`. Use `#arrow-soft` for an optional or exception path.
- `.note` for the lane label and for any condition on an edge, set in 12px and at least 4px clear of the edge.
- `--accent` on at most one step, usually the handoff the reader is asking about.

## Connector rule

Orthogonal only: `M`, `H`, `V`, and axis-aligned `L`. An edge that changes lanes crosses the lane border with a vertical segment, at a right angle, then turns horizontal into its target. Edges within a lane are straight horizontal runs. Every edge is directed and carries a marker, and each endpoint touches its step box within 2px. No curves.

## Multi-line labels

When a label would push its box past the width the layout allows, wrap it onto two lines with one `<tspan>` per line, the `x` repeated on each, and `dy="16.8"` for 14px text. Grow the box to 64 tall and set the first baseline at box center minus 3.5:

```xml
<text class="label" x="128" y="76.5" font-size="14" text-anchor="middle"><tspan x="128">Reserve</tspan><tspan x="128" dy="16.8">inventory</tspan></text>
```

See "Multi-line labels" in `grammar.md` for the arithmetic.

## Lint allowances

- `connector-geometry` rejects `C`, `Q`, `S`, `T`, and `A` commands and diagonal `L` segments (`TYPE_RULES["swimlane"]` has `curves: false`).
- `arrow-marker` requires a resolving marker on every edge.
- A lane group contains its steps; that containment is not an overlap.
- Everything else in `grammar.md` applies unchanged: grid, box height, baseline, padding, spacing, margin, overlap, and caps.

## Worked example

An order crossing from the customer to the warehouse. The handoff edge leaves the bottom of Submit order, drops straight through the gap between lanes, and turns right into Pick items.

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 672 264" width="672" height="264" role="img" aria-labelledby="t d" data-diagram-type="swimlane">
  <title id="t">Order handoff across two teams</title>
  <desc id="d">The Customer lane submits an order. The order crosses into the Warehouse lane, where staff pick the items and then ship the order.</desc>
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
  <g class="group" data-id="lane-customer">
    <rect x="24" y="24" width="624" height="96"/>
    <text class="note" x="80" y="76.2" font-size="12" text-anchor="middle">Customer</text>
    <g class="node" data-id="submit">
      <rect x="136" y="48" width="144" height="48"/>
      <text class="label" x="208.0" y="76.9" font-size="14" text-anchor="middle">Submit order</text>
    </g>
  </g>
  <g class="group" data-id="lane-warehouse">
    <rect x="24" y="144" width="624" height="96"/>
    <text class="note" x="80" y="196.2" font-size="12" text-anchor="middle">Warehouse</text>
    <g class="node" data-id="pick">
      <rect x="304" y="168" width="144" height="48"/>
      <text class="label" x="376.0" y="196.9" font-size="14" text-anchor="middle">Pick items</text>
    </g>
    <g class="node" data-id="ship">
      <rect x="472" y="168" width="144" height="48"/>
      <text class="label" x="544.0" y="196.9" font-size="14" text-anchor="middle">Ship order</text>
    </g>
  </g>
  <path class="edge" data-from="submit" data-to="pick" d="M208 96 V192 H304" marker-end="url(#arrow)"/>
  <path class="edge" data-from="pick" data-to="ship" d="M448 192 H472" marker-end="url(#arrow)"/>
</svg>
```
