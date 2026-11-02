# ER diagrams

An entity-relationship diagram shows stored records and how they point at each other: which tables exist, their key columns, and the cardinality of each link. Read `grammar.md` first; this file only adds what is specific to ER.

## When to use

- Explaining a schema, a migration, or how a feature's data hangs together.
- Showing foreign keys and one-to-many or many-to-many links between a handful of tables.

## When not to

- Requests moving between services: use `architecture` or `sequence`.
- A record changing status over time: use `state`.
- A full dump of every column in a large schema: pick the 3 to 8 tables that matter and list only key and telling columns. Past 12 entities, split into `diagrams/<slug>/` by domain.

## Layout skeleton

- Entities read left to right in dependency order: a parent sits left of (or above) the tables that reference it.
- Each entity is one node box. The top band (48px) holds the table name as the node label at 14px, centered, with a thin divider under it. Below it, one row per column at 12px in the monospace stack, left aligned 16px in from the box edge, 20px apart. Mark keys with `PK` and `FK` after the column name.
- Size every entity box to the widest column plus 12px padding each side, rounded up to the 8px grid. Keep sibling entities the same width when they are close in size; it reads as a table set.
- A join table for a many-to-many link sits between the two tables it joins.
- Keep at least 24px between boxes; 96px between columns of entities leaves room for the cardinality glyphs and labels.

## Classes

- `.node` with `.label` for the table name, plus `.column` (monospace, muted) for column rows and `.divider` for the header rule.
- `.edge` for relationships, `.crow` for the cardinality glyphs, `.note` for cardinality text such as `1` and `N`.
- `.group` only to box a bounded context (for example, billing tables) with a dashed border.

## Connector rule

- Relationships are orthogonal paths (`M`, `H`, `V`, axis-aligned `L`) running from the boundary of one entity to the boundary of the other, ideally at the header band height so they leave the table name, not a column.
- Relationships are undirected: no `marker-end`. Cardinality is drawn at each end instead.
- Cardinality glyphs are separate short paths with class `crow`, not edges: a single bar across the line for "one", and a three-prong crow's foot opening into the entity for "many". Put them 8px to 16px from the box they describe. Diagonal strokes are fine in a glyph because the linter only checks `.edge` geometry.
- Add `1` and `N` (or `0..1`, `1..N`) as 12px notes just above the line, at least 4px clear of it.

## Lint allowances

From `DiagramChecks::TYPE_RULES`: connectors orthogonal, no curves, markers none, endpoints checked.

- `arrow-marker` does not require markers on ER edges.
- Entity boxes hold several texts, so `baseline` is not applied to them; center only the header label and keep its baseline at band center plus 0.35 times 14.
- `text-overflow` still applies to every column row, so a long column name widens the box.

## Worked example

Customer, order, and order line, with two one-to-many links. This exact SVG is the lint fixture `test/fixtures/diagram/clean_er.svg`.

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 816 224" width="816" height="224" role="img" aria-labelledby="t d" data-diagram-type="er">
  <title id="t">Order data model</title>
  <desc id="d">A customer places many orders, and each order holds many order lines. Each line points back to its order by order_id.</desc>
  <style>
    svg { --bg: #FBFBFA; --surface: #FFFFFF; --ink: #1F2328; --muted: #5B6470; --line: #8A939E; --accent: #2F5D8A; --accent-2: #8A5A2F; }
    @media (prefers-color-scheme: dark) {
      svg { --bg: #16181B; --surface: #1E2125; --ink: #E8EAED; --muted: #A3ABB5; --line: #6E7781; --accent: #7FA8D1; --accent-2: #D1A37F; }
    }
    .bg { fill: var(--bg); }
    .node rect { fill: var(--surface); stroke: var(--line); stroke-width: 1.5; }
    .divider { stroke: var(--line); stroke-width: 1; }
    .label { fill: var(--ink); font-family: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", "Noto Sans CJK SC", "Noto Sans CJK JP", sans-serif; }
    .column { fill: var(--muted); font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, "Noto Sans Mono CJK SC", monospace; }
    .edge { fill: none; stroke: var(--line); stroke-width: 1.5; }
    .crow { fill: none; stroke: var(--line); stroke-width: 1.5; }
    .note { fill: var(--muted); font-family: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", "Noto Sans CJK SC", "Noto Sans CJK JP", sans-serif; }
  </style>
  <defs>
    <marker id="arrow" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 Z" fill="#8A939E"/></marker>
    <marker id="arrow-muted" viewBox="0 0 10 10" refX="10" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 Z" fill="#5B6470"/></marker>
  </defs>
  <rect class="bg" x="0" y="0" width="816" height="224" fill="#FBFBFA"/>
  <g class="node" data-id="customer">
    <rect x="48" y="48" width="176" height="128" rx="6"/>
    <text class="label" x="136.0" y="76.9" font-size="14" text-anchor="middle">customer</text>
    <line class="divider" x1="48" y1="96" x2="224" y2="96"/>
    <text class="column" x="64" y="120" font-size="12">id  PK</text>
    <text class="column" x="64" y="140" font-size="12">email</text>
    <text class="column" x="64" y="160" font-size="12">name</text>
  </g>
  <g class="node" data-id="order">
    <rect x="320" y="48" width="176" height="128" rx="6"/>
    <text class="label" x="408.0" y="76.9" font-size="14" text-anchor="middle">order</text>
    <line class="divider" x1="320" y1="96" x2="496" y2="96"/>
    <text class="column" x="336" y="120" font-size="12">id  PK</text>
    <text class="column" x="336" y="140" font-size="12">customer_id  FK</text>
    <text class="column" x="336" y="160" font-size="12">placed_at</text>
  </g>
  <g class="node" data-id="line">
    <rect x="592" y="48" width="176" height="128" rx="6"/>
    <text class="label" x="680.0" y="76.9" font-size="14" text-anchor="middle">order_line</text>
    <line class="divider" x1="592" y1="96" x2="768" y2="96"/>
    <text class="column" x="608" y="120" font-size="12">id  PK</text>
    <text class="column" x="608" y="140" font-size="12">order_id  FK</text>
    <text class="column" x="608" y="160" font-size="12">quantity</text>
  </g>
  <path class="edge" data-from="customer" data-to="order" d="M224 72 H320"/>
  <path class="edge" data-from="order" data-to="line" d="M496 72 H592"/>
  <path class="crow" d="M232 64 V80"/>
  <path class="crow" d="M304 72 L320 64 M304 72 L320 80"/>
  <path class="crow" d="M504 64 V80"/>
  <path class="crow" d="M576 72 L592 64 M576 72 L592 80"/>
  <text class="note" x="244" y="60" font-size="12">1</text>
  <text class="note" x="296" y="60" font-size="12" text-anchor="end">N</text>
  <text class="note" x="516" y="60" font-size="12">1</text>
  <text class="note" x="568" y="60" font-size="12" text-anchor="end">N</text>
</svg>
```
