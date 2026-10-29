---
name: cf:fractal
group: workflow
description: Fractal design reference loaded by name by cf:design, cf:prototype, cf:walkthrough, and cf:roast. Self-similarity as an observable rubric covering one small set of modules repeated at page, section, and component scale, structure that survives phone to desktop, one nesting pattern and one scale ratio at every level, and a repeated proportion that sets visual rhythm. Never overrides cf:usability or the WCAG subset.
---

# Fractal design

This is a reference skill. cf:design, cf:prototype, cf:walkthrough, and cf:roast load it by name; nobody is expected to invoke it directly. It has no auto trigger and carries no usability or accessibility checks of its own: cf:usability and cf:prototyping win every conflict.

Rule: a fractal interface repeats one structural pattern at every scale, so a user who learns one block can read all of them. Zoom into a section and you should see the page again in miniature. The checks below are hypotheses to inspect, not laws.

| Principle | Observable check (screen, DESIGN.md, or recorded sequence) | Default fix |
|---|---|---|
| F1 Repetition of modules | The whole interface is built from a short list of named modules (for example card, row, section). The same module appears at page, section, and component scale | Merge near-duplicates into one module and name it in DESIGN.md |
| F2 Same anatomy at every scale | Each module has the same parts in the same order (title, body, action) whether it fills the page or sits inside a card | Reorder the odd one out to match |
| F3 Structure survives resizing | From phone to desktop the columns, gaps, and module order re-flow, but the modules themselves do not change shape or lose parts | Move the change into the grid; stop swapping components per breakpoint |
| F4 One grid, one unit | Spacing, sizes, and gutters are multiples of a single base unit, and nested grids reuse the parent's unit | Snap strays to the unit tokens |
| F5 Same nesting at each level | Navigation, submenus, and content blocks nest the same way: level two looks and behaves like level one, smaller | Restyle the deeper level as a scaled copy, not a new pattern |
| F6 One scale ratio | Type steps and spacing steps come from one ratio, not hand-picked sizes; every size in use maps to a step | Replace off-scale values with the nearest step |
| F7 Rhythm | Repeated proportions (module aspect, gap-to-content, heading-to-body) recur, so the eye can predict where the next title and action sit | Equalize the proportions that drift |
| F8 Data follows the same pattern | A chart, table, or dashboard tile reuses the module frame, spacing, and type steps of the rest of the page, and a small multiple repeats one chart anatomy | Wrap the chart in the standard module and reuse its axes and label style |

Apply it through:
- Grid layouts: one column grid and one base unit, inherited by every nested container.
- Component design: build the few modules once, compose bigger ones from smaller ones, and let tokens carry the ratio.
- Data visualization: repeat one chart anatomy across the dashboard so comparison is cheap.

Favor:
- Fewer modules used more often over many one-off layouts.
- Naming each module and its scale rule in DESIGN.md so the pattern is checkable.
- Checking at least two scales of the same screen and the recorded sequence, not one still.

Avoid:
- Repetition that hides a difference users must notice. A destructive action or an error must still stand out.
- Monotony: if every block looks identical, nothing signals priority. Repeat structure, vary emphasis.
- Forcing the pattern where a usability or WCAG check fails (target size, contrast, reading order). The check wins and the module gets a documented exception.
- Decorative self-similarity (nested borders, ornament) that serves no recognition.

Output, one line per principle: `F<n> pass`, `F<n> issue (severity <0-4>): <evidence>`, or `F<n> not evaluable: <why>`. Severity uses the cf:usability scale.
