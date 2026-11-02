# Timeline

Events placed in time order along one horizontal axis. Follow `grammar.md` for everything not stated here.

## When to use

- A handful of dated milestones, releases, phases, or incidents where order and rough spacing in time are the point.
- A roadmap or a postmortem sequence that a reader scans left to right.

## When not to

- Steps with branching or decisions: use `flow.md`.
- Messages between actors over time: use `sequence.md`.
- Work split across owners or teams: use `swimlane.md`.
- Quantities over time (counts, rates, durations as bars): that is a chart, so use the dataviz skill.

## Layout skeleton

- One horizontal axis, read left to right, earliest event on the left. Place it in the lower third of the canvas.
- Event nodes sit in one row above the axis, each centered on its point in time. Keep equal gaps between nodes unless the real spacing in time matters; if it does, say so in the `desc`.
- From each node, one vertical tick drops from the node's bottom edge to the axis.
- Dates go below the axis as `.note` text, 12px, centered under their tick, with at least 4px clear of the axis.
- If labels would crowd, alternate nodes above and below the axis rather than shrinking text. Past about eight events, split the timeline into eras, one file each.

## Semantic classes

- `.node` with `.label` for each event. Add a second class such as `lead` to the one milestone the reader should notice first and stroke it in `--accent`.
- `.edge` for the axis: one `<path>` made of a single `H` run.
- `.tick` for the vertical ticks: plain `<line>` elements, stroked in `--line`. Ticks are not edges, so they carry no `data-from` or `data-to`.
- `.note` for dates and any short annotation.
- `.group` is rarely needed; use it only to bracket a named phase spanning several events.

## Connector rule

- The only edge is the axis, and it is horizontal: `M` then `H`, nothing else. A vertical or diagonal `.edge` is a finding.
- No arrowheads. Time direction is carried by left-to-right order, so the axis and ticks carry no `marker-end`.
- No curves.

## Lint allowances

`DiagramChecks::TYPE_RULES["timeline"]` is `connectors: :horizontal, curves: false, markers: :none, endpoints: false`. In practice:

- connector-geometry accepts only flat segments on `.edge` paths.
- arrow-marker is skipped; markers are not required.
- Endpoint checks are skipped, so the axis need not end on a node outline. Its `data-from` and `data-to` name the first and last events for readers of the source.
- Every other grammar rule (grid, box height, baseline, spacing, margins, palette, fonts, caps) applies unchanged.

## Worked example

Three milestones, the middle one highlighted. Saved as `test/fixtures/diagram/clean_timeline.svg`.

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 672 160" width="672" height="160" role="img" aria-labelledby="t d" data-diagram-type="timeline">
  <title id="t">Release timeline</title>
  <desc id="d">Three milestones on one axis, left to right: beta in March, launch in June, and the first patch in August.</desc>
  <style>
    svg { --bg: #FBFBFA; --surface: #FFFFFF; --ink: #1F2328; --muted: #5B6470; --line: #8A939E; --accent: #2F5D8A; --accent-2: #8A5A2F; }
    @media (prefers-color-scheme: dark) {
      svg { --bg: #16181B; --surface: #1E2125; --ink: #E8EAED; --muted: #A3ABB5; --line: #6E7781; --accent: #7FA8D1; --accent-2: #D1A37F; }
    }
    .bg { fill: var(--bg); }
    .node rect { fill: var(--surface); stroke: var(--line); stroke-width: 1.5; }
    .node.lead rect { stroke: var(--accent); stroke-width: 2; }
    .label { fill: var(--ink); font-family: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", "Noto Sans CJK SC", "Noto Sans CJK JP", sans-serif; }
    .edge { fill: none; stroke: var(--line); stroke-width: 1.5; }
    .tick { fill: none; stroke: var(--line); stroke-width: 1.5; }
    .group rect { fill: none; stroke: var(--muted); stroke-dasharray: 4 4; }
    .note { fill: var(--muted); font-family: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", "Noto Sans CJK SC", "Noto Sans CJK JP", sans-serif; }
  </style>
  <defs>
    <marker id="arrow" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 Z" fill="#8A939E"/></marker>
    <marker id="arrow-muted" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 Z" fill="#5B6470"/></marker>
  </defs>
  <rect class="bg" x="0" y="0" width="672" height="160" fill="#FBFBFA"/>
  <g class="node" data-id="beta">
    <rect x="48" y="32" width="160" height="48" rx="6"/>
    <text class="label" x="128.0" y="60.9" font-size="14" text-anchor="middle">Beta</text>
  </g>
  <g class="node lead" data-id="ga">
    <rect x="256" y="32" width="160" height="48" rx="6"/>
    <text class="label" x="336.0" y="60.9" font-size="14" text-anchor="middle">Launch</text>
  </g>
  <g class="node" data-id="patch">
    <rect x="464" y="32" width="160" height="48" rx="6"/>
    <text class="label" x="544.0" y="60.9" font-size="14" text-anchor="middle">First patch</text>
  </g>
  <path class="edge" data-from="beta" data-to="patch" d="M48 104 H624"/>
  <line class="tick" x1="128" y1="80" x2="128" y2="104"/>
  <line class="tick" x1="336" y1="80" x2="336" y2="104"/>
  <line class="tick" x1="544" y1="80" x2="544" y2="104"/>
  <text class="note" x="128" y="128" font-size="12" text-anchor="middle">Mar 2026</text>
  <text class="note" x="336" y="128" font-size="12" text-anchor="middle">Jun 2026</text>
  <text class="note" x="544" y="128" font-size="12" text-anchor="middle">Aug 2026</text>
</svg>
```
