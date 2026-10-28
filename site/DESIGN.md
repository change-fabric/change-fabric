# DESIGN.md

The visual language for the change fabric site (changefabric.org). Read this
before changing anything visual, so the site keeps reading as authored rather
than assembled. It covers the palette, type, spacing, layout, and the theme
mechanism; match what the existing components already do for everything else.

## Brand feeling

Quiet, editorial, precise. Typography and spacing carry the hierarchy; color
is used sparingly. There are no cards, gradients, glows, or colored badges:
lists are rows with hairline separators, sections are separated by space and
rules, and the one accent color is reserved for links, focus, and the single
primary action in an area.

## Colors

Four authored colors. The source of truth is the CSS custom properties in
`src/styles.css`; every other variable there derives from these four by
`color-mix`, never a fifth literal. Nothing mixes toward a white or black
literal.

| Token | Value | Role |
|---|---|---|
| `--cream` | `#f6efe0` | Light ground; dark-theme ink |
| `--plum` | `#24122a` | Light-theme ink; dark ground |
| `--lilac` | `#a070c8` | The accent: links, focus, primary button |
| `--sage` | `#9ea39b` | Muted text and hairlines |

Rule of thumb: plum and cream do almost all the work. Lilac marks what you can
act on; sage marks what is secondary. Neither is used as a fill behind text
except the one primary button.

### Role tables

Light and dark swap roles among the same four colors; nothing is added.

| Semantic token | Light role | Dark role |
|---|---|---|
| `--bg` | `--cream` | `--plum` |
| `--surface` / `--surface-hover` / `--code-bg` | 3% / 7% / 5% `--plum` over `--cream` | 4% / 8% / 6% `--cream` over `--plum` |
| `--border` / `--border-strong` | 60% / 85% `--sage` over `--cream` | 30% / 50% `--sage` over `--plum` |
| `--text` / `--heading` | `--plum` | `--cream` |
| `--muted` | 42% `--sage` in `--plum` | 70% `--sage` in `--cream` |
| `--accent` / `--link` / `--btn` | 62% `--lilac` in `--plum` | 75% `--lilac` in `--cream` |
| `--link-hover` | `--plum` | `--cream` |
| `--btn-text` | `--cream` | `--plum` |
| `--btn-hover` | `--plum` | `--cream` |

Lilac and sage are both too light to be text on cream as authored (3.5:1 and
2.2:1), which is why the light theme deepens each with plum; on plum they are
lifted with cream.

### Derivation recipes

Every non-authored token is a `color-mix(in srgb, A p%, B)` of two authored
tokens, or a `var()` alias of one. For example:

```css
--muted: color-mix(in srgb, var(--sage) 42%, var(--plum));
--accent: color-mix(in srgb, var(--lilac) 62%, var(--plum));
--border: color-mix(in srgb, var(--sage) 60%, var(--cream));
```

`test/site_design_doc_test.rb` fails if any line in the block above is not
found verbatim in `site/src/styles.css`, so the examples cannot drift.

A gray in this system is always sage mixed with the ground, never a separate
neutral value, and there are only two border steps.

### Contrast pairs

This table is checker output, not hand-written: it is regenerated from
`ruby scripts/color_check.rb site --tokens site/src/styles.css --strict`
(WCAG 2.2 SC 1.4.3: 4.5:1 body text, 3:1 large text and UI). CI does not run
it, because the checker needs Chromium in Docker; run it locally after any
token change and paste the new ratios here.

The `--page-*`, `--body-text`, `--code-bg-text`, `--btn-hover-text`, and
`--surface*-text` tokens are measurement aliases (`var()` references to the
role tokens in parentheses) that expose each pair to the checker; components
never use them. `test/site_color_pairs_test.rb` fails if a component paints a
background token that has no alias.

| Pair | Light | Dark |
|---|---|---|
| `--btn-text` on `--btn` | 5.88:1 | 6.56:1 |
| `--btn-hover-text` (`--btn-text`) on `--btn-hover` | 15.35:1 | 15.35:1 |
| `--body-text` (`--text`) on `--background` (`--bg`) | 15.35:1 | 15.35:1 |
| `--page-heading-text` (`--heading`) on `--background` | 15.35:1 | 15.35:1 |
| `--page-link-text` (`--link`) on `--background` | 5.88:1 | 6.56:1 |
| `--page-link-hover-text` (`--link-hover`) on `--background` | 15.35:1 | 15.35:1 |
| `--page-accent-text` (`--accent`) on `--background` | 5.88:1 | 6.56:1 |
| `--page-muted-text` (`--muted`) on `--background` | 6.87:1 | 8.94:1 |
| `--code-bg-text` (`--muted`) on `--code-bg` | 6.23:1 | 7.75:1 |
| `--surface-text` (`--muted`) on `--surface` | 6.48:1 | 8.16:1 |
| `--surface-hover-text` (`--muted`) on `--surface-hover` | 5.98:1 | 7.33:1 |

## Typography

Three stacks, no web fonts:

- `--font-sans` (Inter when installed, else the system UI face) for all text.
- `--font-serif` (Iowan Old Style, Palatino, Georgia) at weight 500 for the
  editorial headings: the wordmark, page titles (`.page-head h1`, 2.4rem),
  the hero title (3.4rem) and subtitle, home section headings (1.9rem),
  changelog release headlines (1.5rem), and `h1` inside the rendered spec.
- `--font-mono` (the system monospace) for identifiers: skill and hook names,
  versions, dates, file names, code.

Body is 15px at 1.6. The sans `h1` default is 1.9rem bold with slight negative
tracking, used only where no serif role above applies; `h2` is 1.2rem at
weight 650; small labels (page eyebrows, group headings, counts) are 0.75
to 0.8rem in `--muted`, sentence case, no uppercase tracking. The one
exception is the homepage hero eyebrow: mono, uppercase, 0.08em tracking, in
`--accent`. Muted text is never below the 4.5:1 floor above.

## Spacing and layout

One 4px-based scale, `--s1` to `--s8` (4, 8, 12, 16, 24, 32, 48, 64px).
Every margin, padding, and gap uses a step, except these, which
`test/site_design_doc_test.rb` holds to exactly this list:

- 1 to 2px hairline nudges;
- 1px 5px around inline code;
- 3px and 6px inside small controls (tags, nav links, buttons) and 6px gaps
  between an icon and its label;
- 36px left padding in the search field, making room for the magnifier;
- 4px and 7px inside the Porcupine phone frames, matching their bezels;
- 112px right padding on the Porcupine hero image, leaving room for the
  phone that overlaps it;
- 80px above each homepage section, and 60px between the hero and the first
  one, larger than the scale on purpose to pace the landing page.

- Every page opens with the same `.page-head`: eyebrow, title, optional lede,
  then `--s5` before content. No giant heading followed by a huge gap.
- Content sits in a 760px measure (the homepage widens to 1040px for its
  two-column audit grid; spec prose is capped at 70ch). From 960px up the site nav is a 224px left
  sidebar (wordmark, section links, then GitHub and the theme toggle pinned to
  the bottom); below that it is a top bar, wrapping to two rows on a phone.
- Lists are rows separated by `--border` hairlines. A row's hover fill bleeds
  `--s2` past the text column via box-shadow, so separators stay on the grid.
- Radius is 6px for controls and code blocks, 3px for inline code and tags,
  and nothing is rounded beyond that.
- Transitions are 120ms on color and background only, disabled under
  `prefers-reduced-motion`. Focus is a 2px `--accent` outline everywhere.

## Themes

The site ships a dark and a light theme; they are the same four colors with
the ground and ink swapped.

Mechanism:

- Default follows the OS via `@media (prefers-color-scheme: dark)`.
- A manual toggle (sun/moon, Phosphor Icons) in the nav overrides the OS
  choice and persists in `localStorage` under `cf-theme`.
- An inline script in `index.html` applies a stored choice before first paint,
  so there is no flash of the wrong theme.
- CSS variables are defined for light in `:root`, for dark in the
  prefers-color-scheme media query, and again under `:root[data-theme="dark|light"]`
  so the manual override wins.
- The four authored tokens are repeated (same values) across the light block
  and both dark blocks, so each theme is self-contained for the checker and
  for anyone reading one block at a time.

When adding a color, derive it from one of the four authored tokens with
`color-mix`; do not add a literal.

## Icons

Phosphor Icons (phosphoricons.com, MIT), regular weight, inlined as SVG with
`fill="currentColor"` so they inherit the theme. Icons appear only where they
aid recognition: GitHub, the theme toggle, and the search field (magnifier
and clear). No decorative row or nav icons. The search field, the
changelog's copy-link button (link, then check once copied) and external
links (an arrow plus screen-reader text, opening in a new tab) are the other
uses. The favicon is the woven change fabric mark, plum and lilac on light,
cream and lilac on dark.

## Do and do not

- Do keep lilac scarce: links, focus, and at most one filled button per area.
- Do derive every new color from `--cream`, `--plum`, `--lilac`, or `--sage`
  with `color-mix`, checked in both themes.
- Do prefer removing styling over adding it: a hairline before a box, a
  weight change before a color.
- Do not introduce a fifth authored color without a stated reason (the
  sanctioned exception is a single `--error` token, if the site ever needs
  one).
- Do not add cards, gradients, shadows, glows, or colored badges.
- Do not hardcode a hex value in a component; use the variables.
