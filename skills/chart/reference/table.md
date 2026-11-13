# Table

A small grid of facts, drawn on the chart skin so it sits beside the other visuals. Follow `grammar.md` for everything not stated here.

## When to use

- A few rows the reader looks values up in: a phase overview, a cost breakdown, a comparison of options.

## When not to

- When the shape of the numbers is the point: draw the chart instead.
- More than about 12 rows or 5 columns: put a Markdown table in the document instead.

## Rules

- `columns` names the header; each row in `rows` has exactly that many cells.
- A column whose cells are all numbers is right-aligned.
- The table must fit the 880 canvas; the renderer refuses a wider one. Shorten cells or split the table.
- No axes, so `axis-label` and `tick-count` do not apply. Each cell is a mark, so `value-fidelity` checks every cell's text.
