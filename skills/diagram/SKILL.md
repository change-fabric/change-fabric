---
name: cf:diagram
group: workflow
description: Hand-placed SVG diagram command. Authors one standalone, theme-aware, accessible .svg per diagram (architecture, flow, sequence, state, ER, timeline, swimlane, layers) from a skill-owned grammar, using the project's DESIGN.md or tokens.css colors when present, then gates it on a Ruby linter that measures text in the pinned browserless container, for up to three fix rounds. Invoked by name only.
---

# CF diagram

Source: own grammar. The default skin, node anatomy, and lint check concepts are adapted from diagram-design (MIT); svg-diagram (MIT) informed further checks. Both are credited in NOTICE.

The agent writes every coordinate by hand. There is no layout engine, no Mermaid, and no generated markup. The grammar in `reference/grammar.md` is the contract, and the linter (`ruby ~/.claude/cf/bin/diagram_lint.rb`) is the judge.

## When to use

Use it for a picture of structure or behavior that a reader should take in at a glance: how services connect, the steps of a process, who calls whom and in what order, the states an object moves through, how tables relate, what happened when, which role does which step, or how a system stacks.

Do not use it for:

- Data charts (bars, lines, scatter, heatmaps). Those go to the dataviz skill.
- UI mocks or screen states. Those go to cf:prototype.
- A picture with more than 12 nodes or 16 edges. Split it into several diagrams instead.

## Inputs

1. The subject: what the diagram has to explain, and to whom.
2. The type, one of `architecture`, `flow`, `sequence`, `state`, `er`, `timeline`, `swimlane`, `layers`. Infer it from the subject when it is obvious, otherwise ask. Each has a reference file in `reference/<type>.md`.
3. `--out <path>`: where the SVG lands. The default is `diagrams/<slug>.svg` in the target repo, or `diagrams/<slug>/<name>.svg` when one run makes several.
4. `--palette <tokens.css>`: an explicit token file. Without it, look for `DESIGN.md` and `tokens.css` at the repo root (the same discovery cf:prototype uses, through `scripts/design_tokens.rb`), and fall back to the default palette in `reference/grammar.md`.

## Procedure

1. Pick the type. Read `reference/grammar.md` and `reference/<type>.md` in full.
2. Sketch in plain text first: the node list with short labels, then the edge list as `from -> to (label)`. Cut anything the reader does not need. Check the caps. Where a node has several outgoing edges, their labels must be exclusive guards that cover every outcome, and every bounded loop needs an edge for the bound running out.
3. Resolve the palette into literal hex values for every role, light and dark. Keep text at 4.5:1 or better against the surface it sits on.
4. Lay out on the 8px grid: pick box widths from the longest label, place rows and columns with at least 24px between siblings, and compute every text baseline from the box center.
5. Write the SVG by hand following the grammar, with `data-diagram-type` on the root.
6. Lint: `ruby ~/.claude/cf/bin/diagram_lint.rb --json <file>` (add `--palette <tokens.css>` when project colors are in use).
7. Fix each finding from its `fix` hint and lint again. Stop after 3 rounds.
8. Report the path, whether text was measured, and any findings left over with their fix hints.

Never loosen a check or edit the linter to make a diagram pass.

## Checks

Each finding carries one of these IDs; `reference/grammar.md` states the rule behind each:

`a11y`, `xml-safety`, `viewbox-clip`, `overlap`, `text-overflow`, `baseline`, `box-height`, `spacing`, `grid`, `connector-geometry`, `arrow-marker`, `palette`, `font-stack`, `theme-fallback`, `caps`, `type-declared`, `transform`, `text-baseline`, `font-unit`, `text-geometry-source`.

The last four reject constructs the geometry model does not follow: any `transform`, a baseline other than alphabetic, a font size that is not unitless or px, and a font size or text anchor declared in a style block.

## Icons

Icons are optional and rarely needed. When one helps, take it from PrototypeIcons (`scripts/prototype_icons.rb`, Phosphor for UI glyphs and Simple Icons for brand marks), inline it as a `<path>` inside the node group, color it with a palette role, and add the notice comment that PrototypeIcons supplies inside the SVG. No other icon source.

## Roast

cf:roast is paid, so it runs only when the user asks for it by name. Never start it on your own.

When asked, render the linted SVG to PNG in the browserless container twice, once as is and once with the dark palette forced, and pass both as `--shot` so the critic judges both themes. Give it `--kind`, an `--audience`, and a `--purpose` per outcome the reader must take away. The SVG adapts to the theme by itself, so a page embedding it needs no theme-aware image swap.

## Failure handling

- Exit 3 means Docker or browserless is unavailable. Re-run with `--no-measure`, treat `text-overflow` as advisory, and tell the user measurement was skipped.
- Exit 2 means bad usage, an unreadable file, or SVG that does not parse. Fix the file, it does not count as a round.
- Metrics come from the pinned Chromium in the browserless container, whose fonts differ from a viewer's. The 12px inner padding is the safety margin. For CJK labels the larger of the measured and the static estimate wins.
- After 3 rounds with findings left, keep the SVG, list the remaining findings, and stop.
- If a guard rejects a subject name, rename the subject to something generic.
