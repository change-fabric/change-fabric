# Bar

Compares one number across a few categories. Follow `grammar.md` for everything not stated here.

## When to use

- A handful of categories, one value each, possibly a few series side by side (grouped bars).
- Use `orientation: "horizontal"` when category names are long or there are more than about 8 of them.

## When not to

- Parts of a whole per category: use `stacked-bar.md`.
- An ordered sequence where the trend matters: use `line.md`.
- Durations with a start and an end: use `schedule.md`.

## Rules

- The value axis starts at 0 [scale-zero]. A bar's length is the value, so a cut axis lies.
- Grouped bars split each category's band evenly across the series, in series order.
- Every series appears in the legend [legend-or-direct-label].

## Example

```json
{ "type": "bar", "title": "Roast cost per round", "x": { "label": "Round", "unit": "" }, "y": { "label": "Cost", "unit": "USD" },
  "series": [ { "name": "estimate", "values": [ ["1", 0.08], ["2", 0.07] ] } ], "desc": "Both rounds stay under 0.10 USD." }
```
