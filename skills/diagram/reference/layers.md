# Layers diagram

A layers diagram shows a system as a stack, where each band rests on the one beneath it. The reader should be able to answer: what sits on top of what, and which layer does a given piece belong to?

## When to use

- A system whose parts are ordered by abstraction or dependency: a network stack, an app from interface down to storage, a platform from hardware up to tenants.
- The point is the ordering itself, and each layer talks mostly to its direct neighbors.
- Up to about 6 layers, each one named by a short noun.

## When not to use

- The parts call each other in many directions, not just up and down: use `architecture`.
- The interest is the order of steps, not the order of layers: use `flow`.
- Messages between parts over time matter: use `sequence`.
- The bands are owners of work rather than levels of a system: use `swimlane`.

## Layout skeleton

- Read top to bottom. The layer closest to the user or caller sits at the top, the foundation at the bottom.
- Every layer is one full-width band of the same width and the same height, left-aligned to a shared x, stacked on the vertical axis.
- Bands keep a 24px gap between them, so each one reads as its own box.
- When a layer holds sub-parts, place them as smaller boxes side by side inside the band, with the band as a `.group`.
- Edges are optional. When used, they are short vertical lines that cross a gap from the bottom of one band to the top of the next.

## Semantic classes

- `.node` with `data-id` per layer, its `<rect>` with a small `rx`, and a centered `.label` naming the layer.
- `.group` when a band contains sub-part nodes; the sub-parts are `.node` elements inside it.
- `.edge` for a dependency line between adjacent bands, with `data-from` and `data-to`.
- `.note` for a short aside at the right of a band, at least 4px clear of it.
- `--accent` on at most one layer, usually the one under discussion.

## Connector rule

Vertical stacking carries the meaning, so edges are optional. Any edge drawn is orthogonal (`M`, `H`, `V`, or axis-aligned `L`), never curved. An edge may skip the arrow marker, since stack order already implies direction; add `#arrow` only when the direction is not top-down. Each endpoint touches its band within 2px.

## Lint allowances

- `arrow-marker` does not require a marker here (`TYPE_RULES["layers"]` has `markers: :optional`). A marker that is present must still resolve.
- `connector-geometry` rejects cubic and quadratic commands, as in every type but state.
- Everything else in `grammar.md` applies unchanged: grid, box height, baseline, padding, spacing, margin, overlap, and caps.

## Worked example

A three-layer web app. The bands share x=48 and width 480, sit 24px apart, and each gap carries one unmarked vertical edge.

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 576 288" width="576" height="288" role="img" aria-labelledby="t d" data-diagram-type="layers">
  <title id="t">Web app layers</title>
  <desc id="d">Three layers stacked top to bottom: Interface, Services, and Storage. Each layer depends only on the one directly below it.</desc>
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
  <rect class="bg" x="0" y="0" width="576" height="288" fill="#FBFBFA"/>
  <g class="node" data-id="interface">
    <rect x="48" y="48" width="480" height="48" rx="4"/>
    <text class="label" x="288.0" y="76.9" font-size="14" text-anchor="middle">Interface</text>
  </g>
  <g class="node" data-id="services">
    <rect x="48" y="120" width="480" height="48" rx="4"/>
    <text class="label" x="288.0" y="148.9" font-size="14" text-anchor="middle">Services</text>
  </g>
  <g class="node" data-id="storage">
    <rect x="48" y="192" width="480" height="48" rx="4"/>
    <text class="label" x="288.0" y="220.9" font-size="14" text-anchor="middle">Storage</text>
  </g>
  <path class="edge" data-from="interface" data-to="services" d="M288 96 V120"/>
  <path class="edge" data-from="services" data-to="storage" d="M288 168 V192"/>
</svg>
```
