# Heatmap

A two-way grid of counts or scores, with color carrying the value. Follow `grammar.md` for everything not stated here.

## When to use

- Where something concentrates across two categorical dimensions: findings by check and phase, failures by route and day.

## When not to

- When exact values matter more than where they cluster: use `table.md`.
- One dimension only: use `bar.md`.

## Rules

- `rows` and `cols` label the grid; `cells` holds one array per row with one number per col.
- `value: { "label", "unit" }` titles the color scale.
- Five ramp steps from `--bg` toward `--accent`, binned evenly between the minimum and the maximum. The ramp is computed from the palette roles, never picked by hand [sequential-contrast].
- A color-scale legend shows the five steps with the minimum and maximum [heatmap-legend].
- Cell values are not printed in the cells; they are in the data table.
