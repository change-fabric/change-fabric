# Scatter

Plots two numeric measures against each other to show a relationship or outliers. Follow `grammar.md` for everything not stated here.

## When to use

- Diff size against findings, cost against duration: does one rise with the other, and which points break the pattern.

## When not to

- One measure across categories: use `bar.md`.
- An ordered sequence: use `line.md`.

## Rules

- `series: [{ "name", "points": [[x, y]] }]`. Use series to separate groups, at most 6.
- Both axes are numeric, so both need a label and a unit [axis-label], and neither is forced to 0.
- No trend line is drawn; say the relationship in `desc`.
