# DESIGN.md

The visual language for the change fabric site (changefabric.org). Read this
before changing anything visual, so the brand stays consistent. It is
deliberately minimal: it covers the navy + gold direction and the theme
mechanism, and nothing else. There is no spacing scale or component catalog to
memorize; match what the existing components already do.

## Brand feeling

Two words: trust and premium quality.

- Navy carries the trust: a deep, calm, dependable base.
- Gold carries the premium quality: a "gold-plated" bar a change has to clear.

Every color choice serves one of those two. If an addition does not read as
either trustworthy-navy or premium-gold, it is off-brand.

## Colors

Four authored colors, two conceptual pairs. The source of truth is the CSS
custom properties in `src/styles.css`; every other variable there derives
from these four by `color-mix`, never a fifth literal.

| Token | Value | Role |
|---|---|---|
| `--navy` | `#123049` | Navy, primary variant |
| `--navy-deep` | `#0d1b2a` | Navy, deep variant |
| `--gold` | `#e6b84a` | Gold, primary variant |
| `--gold-deep` | `#8a6113` | Gold, deep variant |

Rule of thumb: gold is for the one thing you want the eye to go to in a given
area, not for large fills. Navy anchors; gold points.

### Role tables

Light and dark reassign roles among the same four colors; nothing is added.

| Semantic token | Light role | Dark role |
|---|---|---|
| `--bg` | near-white (4% `--navy` over white) | `--navy-deep` |
| `--surface` / `--surface-hover` | near-white, lightly tinted `--navy` | `--navy-deep` lightened toward white |
| `--border` / `--rail` / `--tag-bg` | light tints of `--navy` over white | darker tints of `--navy-deep` toward white |
| `--text` / `--heading` / `--link` | `--navy` | light tint of `--navy` toward white |
| `--muted` | mid tint of `--navy` over white | lighter tint of `--navy` toward white |
| `--link-hover` / `--accent` | `--gold-deep` | `--gold` lightened toward white |
| `--gold-btn` | `--gold` | `--gold` |
| `--gold-btn-text` | `--navy-deep` | `--navy-deep` |
| `--code-bg` | faint tint of `--navy` over white | `--navy-deep` toward black |

### Derivation recipes

Every non-authored token is a `color-mix(in srgb, A p%, B)` of an authored
token against white, black, or `transparent` (alpha over the theme
background). For example:

```css
--bg: color-mix(in srgb, var(--navy) 4%, #ffffff);
--accent-soft: color-mix(in srgb, var(--gold-deep) 12%, transparent);
```

A gray in this system is always a mix or translucent treatment of `--navy`
or `--gold`, never a separate neutral value.

### Contrast pairs

Measured with `ruby ~/.claude/cf/bin/color_check.rb site`, WCAG 2.2 SC 1.4.3
(4.5:1 body text, 3:1 large text and UI):

| Pair | Light | Dark |
|---|---|---|
| `--text` / `--heading` / `--link` on `--bg` | 12.67:1 | 13.08:1 |
| `--link-hover` / `--accent` on `--bg` | 5.15:1 | 10.0:1 |

`--gold-btn-text` on `--gold-btn` is dark navy on gold and is not a
page-background pair; it is checked visually, not by the automated
background check.

## Themes

The site ships a dark and a light theme, and they must read as the same brand,
not two schemes.

- Dark theme: navy background, gold accents and gold link text.
- Light theme: light neutral background, navy for text/headings/nav/links, gold
  for accents, hovers, badges, and CTAs. Both colors are used purposefully here;
  gold is not a token afterthought.

Mechanism:

- Default follows the OS via `@media (prefers-color-scheme: dark)`.
- A manual toggle (sun/moon, Phosphor Icons) in the header overrides the OS
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
`fill="currentColor"` so they inherit the theme. The favicon is the Phosphor
crosshair (a precision/quality-gate motif): gold glyph on a navy rounded tile.

## Do and do not

- Do keep gold scarce and intentional; do keep navy as the anchor.
- Do derive every new color from `--navy`, `--navy-deep`, `--gold`, or
  `--gold-deep` with `color-mix`, checked in both themes.
- Do not introduce a fifth authored color without a stated reason (the
  sanctioned exception is a single `--error` token, if the site ever needs
  one).
- Do not use pure black; the dark base is `--navy-deep`.
- Do not hardcode a hex value in a component; use the variables.
