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
    svg { --bg: #F5F5F5; --surface: #FFFFFF; --ink: #2D3142; --muted: #4F5D75; --soft: #5A6580; --line: #4F5D75; --rule: #D9DADD; --accent: #B5401C; --accent-tint: #F2E9E6; --link: #2E5AA8; }
    @media (prefers-color-scheme: dark) {
      svg { --bg: #2D3142; --surface: #2D3142; --ink: #F5F5F5; --muted: #BFC0C0; --soft: #A3ACC0; --line: #A3ACC0; --rule: #45495A; --accent: #F08A59; --accent-tint: #3D3844; --link: #7FA9E6; }
    }
    .bg { fill: var(--bg); }
    .node rect { fill: var(--surface); stroke: var(--ink); stroke-width: 1; }
    .node.lead rect { stroke: var(--accent); stroke-width: 2; }
    .label { fill: var(--ink); font-weight: 600; font-family: Geist, Inter, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", "Noto Sans CJK SC", "Noto Sans CJK JP", sans-serif; }
    .edge { fill: none; stroke: var(--line); stroke-width: 1.2; }
    #arrow path { fill: var(--line); }
    #arrow-soft path { fill: var(--soft); }
    .tick { fill: none; stroke: var(--line); stroke-width: 1.5; }
    .group rect { fill: none; stroke: var(--muted); stroke-dasharray: 4 4; }
    .note { fill: var(--muted); font-family: Geist, Inter, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", "Noto Sans CJK SC", "Noto Sans CJK JP", sans-serif; }
  </style>
  <defs>
    <marker id="arrow" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 Z" fill="#4F5D75"/></marker>
    <marker id="arrow-soft" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 Z" fill="#5A6580"/></marker>
  </defs>
  <rect class="bg" x="0" y="0" width="672" height="160" fill="#F5F5F5"/>
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
