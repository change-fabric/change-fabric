# Diagram SVG grammar

The shape every cf:diagram SVG takes. The linter checks each rule below; the check ID that enforces it is in brackets.

## Root

One `<svg>` element per file, with:

- `xmlns="http://www.w3.org/2000/svg"`.
- `viewBox="0 0 W H"`, and `width="W"` and `height="H"` set to the same numbers.
- `role="img"` and `aria-labelledby="t d"` [a11y].
- `data-diagram-type` set to one of the eight types [type-declared].

## Children, in order

1. `<title id="t">`: a short name for the diagram.
2. `<desc id="d">`: one or two plain sentences saying what the diagram shows. A screen reader user gets only this, so make it complete.
3. One `<style>` block (below).
4. `<defs>` holding the arrow markers: `#arrow` in `--line`, `#arrow-accent` in `--accent`, `#arrow-link` in `--link`, each with a literal fill.
5. `<rect class="bg">` covering the whole viewBox, with a literal `fill` set to the light background. It keeps the drawing readable in viewers that ignore CSS [theme-fallback].
6. The content: groups, nodes, edges, notes.

## Style block

The `<style>` defines the custom properties on `svg`, then a dark override, then the classes:

```css
svg { --bg: ...; --surface: ...; --ink: ...; --muted: ...; --soft: ...; --line: ...; --rule: ...; --accent: ...; --accent-tint: ...; --link: ...; }
@media (prefers-color-scheme: dark) {
  svg { --bg: ...; --surface: ...; --ink: ...; ... }
}
```

- The dark block must redefine at least `--ink`, `--bg`, and `--surface` [theme-fallback].
- Every value is a literal hex color. Never `var()` into an outside file and never `@import`; the SVG has to stand alone. Translucent roles are written pre-composited over `--bg`, so the palette check can match them.
- Classes: `.bg`, `.node` (box and its texts), `.label` (node name), `.sub` (mono sublabel), `.tag` (mono type tag), `.edge` (connectors, `fill: none`), `.edge-label` (mono arrow label), `.mask` (opaque `--bg` chip behind an arrow label), `.group` (container), `.note` (secondary text), `.callout` (italic serif aside), `.legend` (the bottom strip).

## Skin

The default skin is editorial: a cool off-white paper, near-black ink, one burnt-orange accent, slate secondary text. It is adapted from diagram-design's style guide (MIT, credited in NOTICE), re-tuned so every text role clears 4.5:1 on every surface it sits on in both themes.

### Roles

| role | used for |
|---|---|
| `--bg` | paper: the canvas, arrow-label masks, the node fill under a translucent box |
| `--surface` | the fill of an ordinary node |
| `--ink` | node names and primary node borders |
| `--muted` | sublabels, notes, default connectors and arrowheads |
| `--soft` | arrow labels, group labels, legend text, tags on neutral nodes |
| `--line` | connector strokes (same hue family as muted) |
| `--rule` | hairlines: the legend rule, group borders, external node borders |
| `--accent` | the focal node or path, at most two per diagram |
| `--accent-tint` | the fill of a focal node |
| `--link` | HTTP, API, and external calls |

One accent. A diagram where everything is highlighted has nothing highlighted, so two accented elements is the ceiling.

### Default palette

Used when the project has no DESIGN.md or tokens.css and no `--palette` was passed. Fill and stroke literals outside the resolved palette are a warning [palette].

| role | light | dark |
|---|---|---|
| `--bg` | `#F5F5F5` | `#2D3142` |
| `--surface` | `#FFFFFF` | `#2D3142` |
| `--ink` | `#2D3142` | `#F5F5F5` |
| `--muted` | `#4F5D75` | `#BFC0C0` |
| `--soft` | `#5A6580` | `#A3ACC0` |
| `--line` | `#4F5D75` | `#A3ACC0` |
| `--rule` | `#D9DADD` | `#45495A` |
| `--accent` | `#B5401C` | `#F08A59` |
| `--accent-tint` | `#F2E9E6` | `#3D3844` |
| `--link` | `#2E5AA8` | `#7FA9E6` |

Contrast, computed with `scripts/color_math.rb` (WCAG relative luminance), against the worst surface each role sits on:

| pair | light | dark |
|---|---|---|
| ink on bg | 11.82 | 11.82 |
| muted on bg | 6.11 | 7.07 |
| soft on bg | 5.34 | 5.66 |
| accent on bg | 5.19 | 5.21 |
| accent on accent-tint | 4.73 | 4.59 |
| link on bg | 6.13 | 5.35 |
| line on bg | 6.11 | 5.66 |

`--rule` is decorative and carries no meaning alone. When project tokens replace the defaults, check the same pairs before using them.

### Node treatments

| treatment | fill | stroke |
|---|---|---|
| default | `--surface` | `--ink`, 1 |
| focal (at most 2) | `--accent-tint` | `--accent`, 1.5 |
| store | `--bg` | `--muted`, 1 |
| external | `--bg` | `--rule`, 1, dashed `4 3` |
| optional | `--bg` | `--soft`, 1, dashed `4 3` |

Shape carries the kind of thing (an oval start, a diamond decision, a cylinder store); color carries only focus.

## Type

| role | family | size | weight | use |
|---|---|---|---|---|
| title | serif | 22 | 400 | an in-figure heading, rare |
| label | sans | 14 | 600 | node names, human words |
| sub | mono | 11 | 400 | ports, commands, paths, field types |
| tag | mono | 10 | 500, `letter-spacing="0.08em"`, uppercase | the type tag in a node corner |
| edge-label | mono | 10 | 400, `letter-spacing="0.06em"`, uppercase | arrow labels, legend items |
| note | sans | 12 | 400 | free notes |
| callout | serif italic | 15 | 400 | one editorial aside |

No other sizes. Mono is for technical strings only; a name a person would say goes in sans. Uppercase is written in the text itself, never through `text-transform`. CJK text never goes in a mono or uppercase slot: it switches to 12px sans with no tracking, since the mono faces carry no CJK glyphs.

Stacks, and every `font-family` ends in a generic family and carries a CJK fallback [font-stack]. No bundled or remote fonts; a viewer who has Geist or Instrument Serif installed gets them, everyone else gets the system face:

- sans: `Geist, Inter, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", "Noto Sans CJK SC", "Noto Sans CJK JP", sans-serif`
- mono: `"Geist Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, "Noto Sans Mono CJK SC", monospace`
- serif: `"Instrument Serif", "Iowan Old Style", Georgia, "Noto Serif", "Noto Serif CJK SC", serif`

## Anatomy

### Node

```xml
<g class="node" data-id="api">
  <rect x="48" y="48" width="176" height="80" rx="6"/>
  <rect class="chip" x="60" y="60" width="32" height="16" rx="2"/>
  <text class="tag" x="76" y="72" font-size="10" text-anchor="middle" letter-spacing="0.08em">API</text>
  <text class="label" x="136" y="98" font-size="14" text-anchor="middle">Orders service</text>
  <text class="sub" x="136" y="114" font-size="11" text-anchor="middle">orders:8080</text>
</g>
```

- The box comes first in the group; it is what the linter treats as the node.
- The tag is optional: a 16-tall chip at `rx=2` (a rectangle, not a pill), 12px in from the top left corner, stroked in the node stroke and left unfilled. Keep tags to 2 to 5 letters.
- A node with a tag and a sublabel is 80 tall; with only a name it is 48, and the single-label baseline rule applies.

### Arrow label

```xml
<rect class="mask" x="224" y="52" width="48" height="16" rx="2"/>
<text class="edge-label" x="248" y="64" font-size="10" text-anchor="middle" letter-spacing="0.06em">WRITE</text>
```

At most 14 characters, uppercase, centered on the straight part of its segment, on a `--bg` mask chip. The chip keeps at least 4px off the stroke so the line stays visible [spacing], and never overlaps a node.

### Connectors

| style | stroke | marker |
|---|---|---|
| default | `--line`, 1.2 | `#arrow` |
| primary path | `--accent`, 1.5 | `#arrow-accent` |
| external call | `--link`, 1.2 | `#arrow-link` |
| return, async, optional | any of the above, `stroke-dasharray="5 4"` | matching |

Draw connectors before nodes, so lines sit behind boxes.

### Group

A `<g class="group">` around a `<rect>` stroked in `--rule` (dashed `4 4` for a trust or network boundary), `rx=8`, no fill, with its uppercase mono label in `--soft` sitting on the top border on a mask chip, 16px in from the left.

### Legend

A horizontal strip under the figure, never floating inside it: a `--rule` hairline across the content width, a `LEGEND` eyebrow, then one swatch and edge-label-sized item per treatment actually used, about 160px apart. Grow the viewBox by 64px for it. Wrap it in `<g class="legend">`. Leave it out when the diagram uses one treatment only.

### Dotted paper

Optional, for hero diagrams on their own page: a `<pattern id="dots">` of 1px circles every 24px in `--rule`, painted by a second full-bleed rect over `.bg`. Not for diagrams inside docs or PR bodies.

### Callout

One italic serif aside in `--muted`, beside the thing it explains, with a short `--rule` leader line. Use it for the sentence a reader would otherwise miss.

## Semantic structure

- A node is `<g class="node" data-id="...">` wrapping one shape and its `<text>`. Give the text an `id` when you want findings to name it.
- A connector is `<path class="edge" data-from="<node id>" data-to="<node id>" d="...">`.
- A container is `<g class="group">` around a dashed `<rect>` and the nodes inside it. A group may contain its children; that is not an overlap.

## Geometry

- Grid: node `x`, `y`, `width`, and `height` are multiples of 8 [grid]. Text baselines are exempt.
- Box height: at least 3 times the largest font size in the node, so 48 for a 14px label, plus 1.2 times the font size for each extra label line, and never less than the measured text height plus 24 [box-height].
- Baseline: for text centered in a box, `y = box center + 0.35 * font size`, within 1px. A 48-tall box at `y=48` with 14px text puts the baseline at 72 + 4.9 = 76.9. For a multi-line label the first baseline moves up by half the distance between the first and last baselines [baseline].
- Padding: the full measured text box sits at least 12px inside each side of its node's label box [text-overflow].
- Spacing: at least 24px between sibling boxes, and at least 4px between a label and the edge it describes [spacing].
- Margin: everything sits at least 24px inside the viewBox; content is centered within it [viewbox-clip].
- Overlap: no two node boxes intersect, no two text boxes touch, and no text crosses an edge [overlap].
- Caps: at most 12 nodes and 16 edges. Past that, split into `diagrams/<slug>/` [caps].

## Text boxes

- The linter measures each `<text>` in the pinned Chromium with `getBBox`, which returns a full box: x, y, width, and height, with the anchor, the baseline, and every tspan already resolved. With `--no-measure` it falls back to an estimate (0.6em per character, 1.2em per line, placed from `text-anchor`) and reports `text-overflow` as a warning.
- Containment is one predicate: the text box must fit inside the node's label box inset by 12px on every side. It catches a label that is too wide, one placed off center so it runs past an edge, and one that is too tall or sits below the box, for every node type, ER entities included [text-overflow].
- The label box is the shape's bounding box for a `<rect>`. For a round or polygon node it is the inscribed box: a square of side `r * sqrt(2)` for a circle, `rx * sqrt(2)` by `ry * sqrt(2)` for an ellipse, and the largest axis-aligned box centered on a polygon's centroid that stays inside it. Size a diamond or circle so the label fits that smaller box. Connector endpoints still touch the shape's bounding box.
- Text crossing an edge, and the 4px clearance between a label and its edge, are exact segment to box tests; curves are flattened into chords first [overlap] [spacing].

## Multi-line labels

A label that would make its box too wide may wrap onto two or three lines. Write one `<tspan>` per line, repeat the `x` on every line, and step down with `dy` in px (1.2 times the font size):

```xml
<rect x="48" y="48" width="160" height="64"/>
<text class="label" x="128" y="76.5" font-size="14" text-anchor="middle">
  <tspan x="128">Reserve</tspan>
  <tspan x="128" dy="16.8">inventory</tspan>
</text>
```

The 64-tall box holds 42 + 16.8 = 58.8. The first baseline is 80 + 4.9 - 8.4 = 76.5, so the block centers on the box [box-height] [baseline].

## Prohibited constructs

The geometry model reads raw coordinates, so anything that moves glyphs or boxes away from them is an error:

- No `transform`, as an attribute on any element or as a property in a style [transform].
- No `dominant-baseline` or `alignment-baseline` other than `alphabetic`, set on the text or inherited from a group or style [text-baseline].
- `font-size` is unitless or px only, such as `14` or `14px`. Never `em`, `rem`, `%`, or a keyword [font-unit].
- `font-size` and `text-anchor` go on the text or a group as attributes or inline style, never in a style block [text-geometry-source].

## Connectors

- Default is orthogonal: only `M`, `H`, `V`, and `L` commands, and every `L` is axis-aligned. `C` and `Q` are allowed only where the type reference says so (state self-loops and back-edges) [connector-geometry].
- Each endpoint touches the boundary of its `data-from` or `data-to` node within 2px, and no segment passes through another node [connector-geometry].
- A directed edge ends in `marker-end` naming one of the markers in `<defs>`, which must resolve to a marker in `<defs>` [arrow-marker]. ER relationships and timeline ticks carry no arrows.
- Route around nodes with one or two bends rather than many. Prefer edges that leave the side facing the target.

## Forbidden

No `<script>`, `<foreignObject>`, event attributes such as `onclick`, remote `href`, `<image>` pointing off the file, filters, shadows, or gradients. Escape `&`, `<`, and `>` in text as entities [xml-safety].
