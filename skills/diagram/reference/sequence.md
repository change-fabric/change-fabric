# Sequence diagrams

Read `grammar.md` first. This file only adds what is specific to sequence diagrams.

## When to use

Use a sequence diagram when the question is "who talks to whom, and in what order": a request crossing services, a handshake, a retry, a callback. Time runs down the page and each message is one row.

## When not to

- The order of steps matters but the actors do not: use `flow.md`.
- You want to show which parts exist and how they connect, not one run through them: use `architecture.md`.
- Work moves between teams or roles over a process: use `swimlane.md`.
- One thing changes mode in response to events: use `state.md`.

## Layout skeleton

- Participants sit in one row of node boxes across the top, left to right in the order they first speak. The caller is leftmost.
- Each participant drops a vertical lifeline from the center of its box bottom to just below the last message.
- Time runs top to bottom. Each message is a horizontal arrow from the sender lifeline to the receiver lifeline, on its own row, with rows spaced evenly (56px works for a 12px label).
- The message label sits centered above its arrow, at least 4px clear of it.
- Keep it to 3 to 5 participants and at most 12 messages; split a longer exchange into several diagrams.

## Classes

- `.node` with `.label` for participant boxes.
- `.lifeline` for the vertical dashed lines, drawn as `<line>`, not as `.edge`. Add its rule to the style block, stroked in `--line`.
- `.edge` for request messages, with `marker-end="url(#arrow)"`.
- `.edge.reply` for return messages, dashed and stroked in `--muted`, with `marker-end="url(#arrow-soft)"`.
- `.note` for message labels at 12px.
- `--accent` on at most one message or participant, the one the diagram is about.

## Connector rule

Messages are horizontal only: a single `M x y H x` segment between two lifelines. No bends, no curves, no diagonals. Lifelines are vertical. Every message carries an arrow marker. A self-call is not drawn as a loop; write it as a note beside the lifeline instead.

## Lint allowances

- `TYPE_RULES["sequence"]`: connectors `horizontal`, curves not allowed, markers required.
- Endpoint snapping is off: a message starts and ends on a lifeline, not on a participant box, so `data-from` and `data-to` name the participants but the endpoints are not checked against their boxes.
- Lifelines are not edges, so they are exempt from the connector checks.

## Worked example

A client creates an order through an API that writes to a database. This exact SVG is `test/fixtures/diagram/clean_sequence.svg` and passes `diagram_lint.rb --no-measure`.

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 576 384" width="576" height="384" role="img" aria-labelledby="t d" data-diagram-type="sequence">
  <title id="t">Order creation sequence</title>
  <desc id="d">A client posts an order to the API, the API inserts it into the database and gets back a row id, then the API answers the client with 201 Created.</desc>
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
    .lifeline { stroke: var(--line); stroke-width: 1; stroke-dasharray: 4 4; }
    .edge.reply { stroke: var(--muted); stroke-dasharray: 6 4; }
    .note { fill: var(--muted); font-family: Geist, Inter, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", "Noto Sans CJK SC", "Noto Sans CJK JP", sans-serif; }
  </style>
  <defs>
    <marker id="arrow" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 Z" fill="#4F5D75"/></marker>
    <marker id="arrow-soft" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 Z" fill="#5A6580"/></marker>
  </defs>
  <rect class="bg" x="0" y="0" width="576" height="384" fill="#F5F5F5"/>
  <g class="node" data-id="client">
    <rect x="48" y="48" width="128" height="48" rx="6"/>
    <text class="label" x="112.0" y="76.9" font-size="14" text-anchor="middle">Client</text>
  </g>
  <g class="node" data-id="api">
    <rect x="224" y="48" width="128" height="48" rx="6"/>
    <text class="label" x="288.0" y="76.9" font-size="14" text-anchor="middle">API</text>
  </g>
  <g class="node" data-id="db">
    <rect x="400" y="48" width="128" height="48" rx="6"/>
    <text class="label" x="464.0" y="76.9" font-size="14" text-anchor="middle">Database</text>
  </g>
  <line class="lifeline" x1="112" y1="96" x2="112" y2="344"/>
  <line class="lifeline" x1="288" y1="96" x2="288" y2="344"/>
  <line class="lifeline" x1="464" y1="96" x2="464" y2="344"/>
  <text class="note" x="200.0" y="142" font-size="12" text-anchor="middle">POST /orders</text>
  <path class="edge" data-from="client" data-to="api" d="M112 152 H288" marker-end="url(#arrow)"/>
  <text class="note" x="376.0" y="198" font-size="12" text-anchor="middle">INSERT order</text>
  <path class="edge" data-from="api" data-to="db" d="M288 208 H464" marker-end="url(#arrow)"/>
  <text class="note" x="376.0" y="254" font-size="12" text-anchor="middle">row id</text>
  <path class="edge reply" data-from="db" data-to="api" d="M464 264 H288" marker-end="url(#arrow-soft)"/>
  <text class="note" x="200.0" y="310" font-size="12" text-anchor="middle">201 Created</text>
  <path class="edge reply" data-from="api" data-to="client" d="M288 320 H112" marker-end="url(#arrow-soft)"/>
</svg>
```
