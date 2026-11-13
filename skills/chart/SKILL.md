---
name: cf:chart
group: workflow
description: Data chart command. Renders one standalone, theme-aware, accessible .svg per chart (bar, stacked-bar, line, schedule, table, scatter, heatmap) from a chart.json data spec with a deterministic Ruby renderer on cf:diagram's skin and palette, then gates it on a Ruby linter that runs cf:diagram's shared SVG checks plus chart checks (axis titles and units, zero baselines, tick counts, series cap, legends, a data table, and mark geometry against the spec), for up to three fix rounds. Invoked by name, or loaded by cf:plan and cf:drive thorough.
---

# CF chart

cf:chart is the data sibling of cf:diagram. It borrows cf:diagram's skin, color roles, palette resolver, text measurer, PNG renderer and every shared SVG check (`scripts/svg_checks.rb`), and adds a renderer and the chart-only checks.

## Why charts are generated, not hand-placed

A diagram is a drawing: its author chooses where each box goes, so cf:diagram has the agent place every coordinate by hand. A chart is a measurement: each bar length, point and cell color must be exactly what the data says, and the geometry follows from the data alone. Hand-placing it invites values that look right and are wrong. So the agent writes only the data, as `chart.json`, and `scripts/chart_render.rb` computes every coordinate. The same spec always gives the same bytes. The lint re-renders the spec to confirm each mark (`value-fidelity`).

## When to use

Use it for quantities a reader compares: cost per round, findings per phase, a trend, durations on a calendar, a small table of facts, a correlation, or a two-way grid of counts.

Do not use it for:

- Structure or behavior (services, steps, states, events in order). Those go to cf:diagram.
- UI mocks. Those go to cf:prototype.
- More than 6 series. Split the chart or group the small series.

### Schedule versus cf:diagram's timeline

A cf:diagram `timeline` is events in order: milestones placed left to right, evenly spaced unless spacing matters. A cf:chart `schedule` is durations on a scaled time axis: each task is a bar from its start to its end, so length and overlap are exact. Pick the timeline for "what happened when" and the schedule for "how long, and what runs at the same time".

## Inputs

1. The data and the question it answers.
2. The type, one of `bar`, `stacked-bar`, `line`, `schedule`, `table`, `scatter`, `heatmap`. Each has a reference file in `reference/<type>.md`.
3. `--out <path>`: where the SVG lands. The default is `charts/<slug>.svg` in the target repo, or beside the plan's other visuals when cf:plan loads this skill.
4. `--repo <dir>` or `--tokens <file>`: whose brand to draw in. With either, the renderer resolves the token file through `scripts/diagram_palette.rb` exactly as cf:diagram does. Without, it uses the default skin in `skills/diagram/reference/grammar.md`.

## Procedure

1. Pick the type. Read `reference/grammar.md` and `reference/<type>.md` in full.
2. Write `chart.json` next to the SVG (same slug). Title it with the finding, not the topic, and put the one-sentence takeaway in `desc`: a screen reader user gets only the desc and the data table.
3. Render: `ruby ~/.claude/cf/bin/chart_render.rb <chart.json> --out <file.svg> --repo <target repo>`. Exit 2 is a bad spec; the message names the field.
4. Lint: `ruby ~/.claude/cf/bin/chart_lint.rb --json --spec <chart.json> [--palette <tokens file>] <file.svg>`, with the same token file the render resolved (omit `--palette` on the default skin).
5. Fix each finding by changing `chart.json` and rendering again, never by editing the SVG. Stop after 3 rounds.
6. Report the path, whether text was measured, and any findings left with their fix hints.

Never loosen a check or edit the linter to make a chart pass.

## Checks

Shared with cf:diagram (`scripts/svg_checks.rb`): `a11y`, `xml-safety`, `viewbox-clip`, `text-overflow`, `palette`, `font-stack`, `theme-fallback`, `transform`, `text-baseline`, `font-unit`, `text-geometry-source`, `display-scale`.

Chart checks (`scripts/chart_checks.rb`):

- `type-declared`: `data-chart-type` is one of the seven types.
- `axis-label`: every axis is titled, and a numeric or time axis carries a unit. Not for table.
- `scale-zero`: a bar or stacked-bar value axis includes 0 and draws its baseline there.
- `tick-count`: a numeric or time axis has 3 to 8 ticks.
- `series-cap`: at most 6 series, each in one of the six categorical colors.
- `legend-or-direct-label`: every series is named by a legend entry or a direct label.
- `data-table`: the hidden `<g data-role="data-table">` carries every value.
- `value-fidelity`: every mark matches what the spec renders to. Without `--spec` this is a notice, not an error.
- `heatmap-legend`: a heatmap shows its color scale.
- `sequential-contrast`: the heatmap ramp is derived from the palette roles, rises in contrast step by step, and its top step clears 3:1 on the background in both themes.

## Roast

cf:roast is paid. Used on its own, cf:chart follows cf:diagram's rule: roast only when the user asks for it by name, never on your own. When cf:plan loads this skill, cf:plan's own roast covers the charts.

When asked, render PNGs with `ruby ~/.claude/cf/bin/diagram_render.rb <file.svg>` (it writes `-light.png` and `-dark.png`), pass both as `--shot`, and re-render and re-lint after each accepted fix.

## Failure handling

- Exit 3 from the lint means Docker or browserless is unavailable. Re-run with `--no-measure`, treat `text-overflow` as advisory, and say measurement was skipped.
- Exit 2 means bad usage, an unreadable file, an unparseable SVG or spec. Fix it; it does not count as a round.
- A table wider than the canvas fails to render. Shorten the cells or split the table.
- After 3 rounds with findings left, keep the SVG, list the remaining findings, and stop.
