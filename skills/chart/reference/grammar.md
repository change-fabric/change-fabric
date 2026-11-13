# Chart grammar

The `chart.json` schema `scripts/chart_render.rb` reads, and the SVG it writes. Skin, color roles, the default palette, contrast floors and the font stacks are cf:diagram's: read `skills/diagram/reference/grammar.md` for them rather than a copy here.

## chart.json

Common fields, every type:

| field | required | meaning |
|---|---|---|
| `type` | yes | `bar`, `stacked-bar`, `line`, `schedule`, `table`, `scatter` or `heatmap` |
| `title` | yes | the finding in a few words, shown on the chart and used as `<title>` |
| `desc` | no, but write it | one or two sentences with the takeaway, used as `<desc>` |
| `x`, `y` | per type | `{ "label": "...", "unit": "..." }` for each axis |

Per type:

| type | data fields | axes |
|---|---|---|
| `bar` | `series: [{ name, values: [[key, number]] }]`, `orientation`: `vertical` (default) or `horizontal` | `x` is always the category axis, `y` the value axis, whatever the orientation |
| `stacked-bar` | as bar; values of one key stack in series order | as bar |
| `line` | `series: [{ name, values: [[key, number]] }]` | `x` category, `y` value |
| `scatter` | `series: [{ name, points: [[x, y]] }]` | both numeric |
| `schedule` | `tasks: [{ name, start, end }]`, start and end as ISO dates (`2026-11-02`) or numbers | `x` time, `y` the tasks |
| `table` | `columns: [...]`, `rows: [[...]]`, each row as long as `columns` | none |
| `heatmap` | `rows: [...]`, `cols: [...]`, `cells`: one array of numbers per row, one number per col; `value: { label, unit }` titles the color scale | `x` the cols, `y` the rows |

Units: a numeric or time axis needs a `unit` (`USD`, `count`, `day`) [axis-label]. A category axis needs only a `label`; its `unit` may be empty.

Keys are matched as strings, so `"1"` and `1` name the same category. Categories keep the order they first appear in across the series.

## The SVG

The renderer writes, in order:

1. The root `<svg>` with `viewBox="0 0 880 H"`, `role="img"`, `aria-labelledby="t d"` and `data-chart-type` [a11y, type-declared].
2. `<title id="t">` and `<desc id="d">`.
3. One `<style>`: cf:diagram's roles for light and dark, plus the derived `--s1` to `--s6` series colors and the `--ramp-1` to `--ramp-5` heatmap ramp.
4. `<rect class="bg">` with a literal light fill [theme-fallback].
5. The chart title, then one `<g class="axis">` per axis carrying `data-axis`, `data-role`, `data-scale` (`linear`, `time` or `band`), `data-label`, `data-unit`, and for numeric axes `data-min` and `data-max`. Its ticks are `<line class="tick" data-value>`; its title is `<text class="axis-title">`.
6. `<g class="marks">`: each mark carries `class="mark sN"` (or `ramp-N` in a heatmap), `data-series`, `data-key` and `data-value`.
7. A `<g class="legend">` for series types, or `<g class="scale-legend">` for a heatmap.
8. `<g data-role="data-table">` holding one `<desc>` per value: the text alternative [data-table].

## Colors

- Series take `--s1` to `--s6` in order: accent, link, ink, then accent and link mixed, then accent and link each mixed toward the background. Six is the cap [series-cap].
- The heatmap ramp mixes `--accent` into `--bg` at 20, 40, 60, 80 and 100 percent. Values are binned into five equal steps between the minimum and the maximum [sequential-contrast].
- These derived colors are computed from the resolved roles, so the lint's palette includes them; `--palette` on the lint adds them for a token file too.

## Scales and ticks

Numeric axes use steps of 1, 2 or 5 times a power of ten, the smallest that gives at most 6 ticks, so every axis lands in 3 to 8 [tick-count]. Bar and stacked-bar value axes always include 0 [scale-zero]. Date axes step in whole days and label ticks like `Nov 5`.

## What the renderer will not do

No rotated text (the shared `transform` check forbids it, so the value axis title sits above the plot), no dual axes, no pie or donut, no 3D, no animation. When the data needs one of these, pick a different type or split the chart.
