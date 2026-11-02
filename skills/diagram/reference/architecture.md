# Architecture diagrams

Declare with `data-diagram-type="architecture"`. Follow `grammar.md` for everything not stated here.

## When to use

Use an architecture diagram to show which components a system is made of and which ones talk to which. The reader should come away knowing the parts, the boundaries between them (networks, accounts, trust zones), and the direction each dependency runs. Time and order do not matter here; structure does.

## When not to

- The order of calls matters, or one request is traced across components: use `sequence`.
- The diagram is about decisions and steps rather than components: use `flow`.
- Each component belongs to a team or actor and the handoffs are the point: use `swimlane`.
- The system is a strict stack where each tier only talks to the one below: use `layers`.
- The boxes are tables with columns and keys: use `er`.

## Layout skeleton

- Read left to right. Put the entry point (a user, a browser, a client) on the left and the deepest dependency (storage, third parties) toward the right or the bottom.
- Lay nodes on a loose grid of columns and rows. Columns carry the main request path; a second row holds what the main path depends on, such as storage under the service that writes to it.
- Wrap components that share a boundary in a `<g class="group">` with a dashed rect and a short `note` label in its top left corner. Keep at least 32px between the group border and the nodes inside it, so the label has room.
- Keep nodes in one diagram the same width where you can. Uneven widths read as importance.
- Mark the one component the diagram is about with the accent stroke. Leave the rest neutral.

## Semantic classes

- `.node` for every component, `.label` for its name.
- `.group` for network, account, or trust boundaries. Groups may nest one level; deeper than that, split the diagram.
- `.edge` for dependencies, drawn from caller to callee.
- `.note` for the group label and short edge labels (a protocol, a verb such as `enqueue`).
- A `lead` class added to a node (`class="node lead"`) for the accented component, styled in the style block with `var(--accent)`.

## Connectors

- Orthogonal only: `M`, `H`, `V`, and axis-aligned `L`. No `C` or `Q`.
- Every edge is directed and ends in `marker-end="url(#arrow)"`. Use `#arrow-muted` for optional or asynchronous paths when the diagram also has synchronous ones, and say so in the desc.
- Point the arrow the way the call goes, not the way data comes back. A read from a database still points at the database.
- Prefer a straight edge between neighbors in the same row or column. When a bend is needed, use one or two, and route along the gap between columns rather than through a group label.
- An edge may cross a group border; that is how traffic enters a boundary. It may not cross a node.

## Multi-line labels

When a label would push its box past the width the layout allows, wrap it onto two lines with one `<tspan>` per line, the `x` repeated on each, and `dy="16.8"` for 14px text. Grow the box to 64 tall and set the first baseline at box center minus 3.5:

```xml
<text class="label" x="128" y="76.5" font-size="14" text-anchor="middle"><tspan x="128">Reserve</tspan><tspan x="128" dy="16.8">inventory</tspan></text>
```

See "Multi-line labels" in `grammar.md` for the arithmetic.

## Lint allowances

- `connector-geometry`: orthogonal policy, curves rejected.
- `arrow-marker`: required on every edge.
- `overlap`: a group rect contains its nodes and its label; that containment is not a finding. Nodes inside different groups must still keep the 24px sibling gap.
- `caps`: the usual 12 nodes and 16 edges. A system bigger than that becomes an overview diagram plus one diagram per group under `diagrams/<slug>/`.

## Worked example

An upload path: a browser calls an API inside a private network; the API writes metadata to a database and enqueues work for a worker that writes to an object store. The API is the accented lead node. This exact file is `test/fixtures/diagram/clean_architecture.svg` and lints clean.

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 720 320" width="720" height="320" role="img" aria-labelledby="t d" data-diagram-type="architecture">
  <title id="t">Upload service architecture</title>
  <desc id="d">A browser sends uploads to an API inside a private network. The API records metadata in a database and enqueues work for a worker, which writes processed files to an object store.</desc>
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
    .group rect { fill: none; stroke: var(--muted); stroke-dasharray: 4 4; }
    .note { fill: var(--muted); font-family: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", "Noto Sans CJK SC", "Noto Sans CJK JP", sans-serif; }
  </style>
  <defs>
    <marker id="arrow" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 Z" fill="#8A939E"/></marker>
    <marker id="arrow-muted" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 Z" fill="#5B6470"/></marker>
  </defs>
  <rect class="bg" x="0" y="0" width="720" height="320" fill="#FBFBFA"/>
  <g class="group" data-id="private">
    <rect x="240" y="56" width="432" height="208" rx="8"/>
    <text class="note" x="256" y="76" font-size="12">private network</text>
  </g>
  <g class="node" data-id="browser">
    <rect x="48" y="88" width="144" height="48" rx="6"/>
    <text class="label" x="120" y="116.9" font-size="14" text-anchor="middle">Browser</text>
  </g>
  <g class="node lead" data-id="api">
    <rect x="272" y="88" width="144" height="48" rx="6"/>
    <text class="label" x="344" y="116.9" font-size="14" text-anchor="middle">Upload API</text>
  </g>
  <g class="node" data-id="worker">
    <rect x="496" y="88" width="144" height="48" rx="6"/>
    <text class="label" x="568" y="116.9" font-size="14" text-anchor="middle">Worker</text>
  </g>
  <g class="node" data-id="db">
    <rect x="272" y="200" width="144" height="48" rx="6"/>
    <text class="label" x="344" y="228.9" font-size="14" text-anchor="middle">Database</text>
  </g>
  <g class="node" data-id="store">
    <rect x="496" y="200" width="144" height="48" rx="6"/>
    <text class="label" x="568" y="228.9" font-size="14" text-anchor="middle">Object store</text>
  </g>
  <path class="edge" data-from="browser" data-to="api" d="M192 112 H272" marker-end="url(#arrow)"/>
  <path class="edge" data-from="api" data-to="worker" d="M416 112 H496" marker-end="url(#arrow)"/>
  <path class="edge" data-from="api" data-to="db" d="M344 136 V200" marker-end="url(#arrow)"/>
  <path class="edge" data-from="worker" data-to="store" d="M568 136 V200" marker-end="url(#arrow)"/>
  <text class="note" x="456" y="102" font-size="12" text-anchor="middle">enqueue</text>
</svg>
```
