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
4. `<defs>` holding the arrow markers: `#arrow` stroked in the line color and `#arrow-muted` in the muted color.
5. `<rect class="bg">` covering the whole viewBox, with a literal `fill` set to the light background. It keeps the drawing readable in viewers that ignore CSS [theme-fallback].
6. The content: groups, nodes, edges, notes.

## Style block

The `<style>` defines the custom properties on `svg`, then a dark override, then the classes:

```css
svg { --bg: ...; --surface: ...; --ink: ...; --muted: ...; --line: ...; --accent: ...; --accent-2: ...; }
@media (prefers-color-scheme: dark) {
  svg { --bg: ...; --surface: ...; --ink: ...; --muted: ...; --line: ...; --accent: ...; --accent-2: ...; }
}
```

- The dark block must redefine at least `--ink`, `--bg`, and `--surface` [theme-fallback].
- Every value is a literal color. Never `var()` into an outside file and never `@import`; the SVG has to stand alone.
- Classes: `.bg`, `.node` (box and its label), `.label` (text inside a node), `.edge` (connectors, `fill: none`), `.group` (dashed container), `.note` (secondary text in the muted color).

## Roles

| role | used for |
|---|---|
| `--bg` | the canvas behind everything |
| `--surface` | node fills |
| `--ink` | primary text |
| `--muted` | notes, edge labels, secondary text, dashed group borders |
| `--line` | node borders, connectors, arrowheads |
| `--accent` | the one node or path the reader should notice first |
| `--accent-2` | a second highlight, used sparingly |

Use accent on at most a few elements. A diagram where everything is highlighted has nothing highlighted.

## Default palette

Used when the project has no DESIGN.md or tokens.css and no `--palette` was passed. Fill and stroke literals outside the resolved palette are a warning [palette].

| role | light | dark |
|---|---|---|
| `--bg` | `#FBFBFA` | `#16181B` |
| `--surface` | `#FFFFFF` | `#1E2125` |
| `--ink` | `#1F2328` | `#E8EAED` |
| `--muted` | `#5B6470` | `#A3ABB5` |
| `--line` | `#8A939E` | `#6E7781` |
| `--accent` | `#2F5D8A` | `#7FA8D1` |
| `--accent-2` | `#8A5A2F` | `#D1A37F` |

Contrast, computed with `scripts/color_math.rb` (WCAG relative luminance):

| pair | light | dark |
|---|---|---|
| ink on surface | 15.80 | 13.41 |
| ink on bg | 15.26 | 14.76 |
| muted on surface | 6.00 | 6.96 |
| accent on surface | 6.88 | 6.48 |
| accent-2 on surface | 5.86 | 7.12 |
| line on surface | 3.11 | 3.55 |

Every text role clears AA (4.5:1) in both themes. `--line` is for strokes only and clears the 3:1 non-text minimum; never set text in it. When project tokens replace the defaults, check the same pairs before using them.

## Type

- Sizes: 12 (notes, edge labels), 14 (node labels), 18 (titles or a lead node). No other sizes.
- Sans stack, on every text class:
  `system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans", "Noto Sans CJK SC", "Noto Sans CJK JP", sans-serif`
- Monospace stack, for identifiers, column types, and code:
  `ui-monospace, SFMono-Regular, Menlo, Consolas, "Noto Sans Mono CJK SC", monospace`
- Every `font-family` ends in a generic family and carries a CJK fallback [font-stack]. No bundled or remote fonts.

## Semantic structure

- A node is `<g class="node" data-id="...">` wrapping one shape and its `<text>`. Give the text an `id` when you want findings to name it.
- A connector is `<path class="edge" data-from="<node id>" data-to="<node id>" d="...">`.
- A container is `<g class="group">` around a dashed `<rect>` and the nodes inside it. A group may contain its children; that is not an overlap.

## Geometry

- Grid: node `x`, `y`, `width`, and `height` are multiples of 8 [grid]. Text baselines are exempt.
- Box height: at least 3 times the label font size, so 48 for a 14px label, plus 1.2 times the font size for each extra label line, and never less than the measured text height plus 24 [box-height].
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

## Connectors

- Default is orthogonal: only `M`, `H`, `V`, and `L` commands, and every `L` is axis-aligned. `C` and `Q` are allowed only where the type reference says so (state self-loops and back-edges) [connector-geometry].
- Each endpoint touches the boundary of its `data-from` or `data-to` node within 2px, and no segment passes through another node [connector-geometry].
- A directed edge ends in `marker-end="url(#arrow)"` or `url(#arrow-muted)`, which must resolve to a marker in `<defs>` [arrow-marker]. ER relationships and timeline ticks carry no arrows.
- Route around nodes with one or two bends rather than many. Prefer edges that leave the side facing the target.

## Forbidden

No `<script>`, `<foreignObject>`, event attributes such as `onclick`, remote `href`, `<image>` pointing off the file, filters, shadows, or gradients. Escape `&`, `<`, and `>` in text as entities [xml-safety].
