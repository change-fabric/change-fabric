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
from these four by `color-mix`, never a fifth literal. White and black
count as authored colors too, so the light neutral is `--paper` and
nothing mixes toward a literal.

| Token | Value | Role |
|---|---|---|
| `--navy` | `#123049` | Navy, primary variant |
| `--navy-deep` | `#0d1b2a` | Navy, deep variant |
| `--gold` | `#e6b84a` | Gold, primary variant |
| `--paper` | `#ffffff` | Light neutral |

Rule of thumb: gold is for the one thing you want the eye to go to in a given
area, not for large fills. Navy anchors; gold points.

### Role tables

Light and dark reassign roles among the same four colors; nothing is added.

| Semantic token | Light role | Dark role |
|---|---|---|
| `--bg` | near-white (4% `--navy` over `--paper`) | `--navy-deep` |
| `--surface` / `--surface-hover` | near-white, lightly tinted `--navy` | `--navy-deep` lightened toward `--paper` |
| `--border` / `--rail` / `--tag-bg` | light tints of `--navy` over `--paper` | darker tints of `--navy-deep` toward `--paper` |
| `--text` / `--heading` | `--navy` | light tint of `--navy` toward `--paper` |
| `--link` | `--navy` | `--gold` |
| `--muted` | mid tint of `--navy` over `--paper` | lighter tint of `--navy` toward `--paper` |
| `--link-hover` / `--accent` | `--gold-deep` (50% `--gold` in `--navy-deep`) | `--gold` lightened toward `--paper` |
| `--gold-btn` | `--gold` | `--gold` |
| `--gold-btn-text` | `--navy-deep` | `--navy-deep` |
| `--code-bg` | faint tint of `--navy` over `--paper` | `--navy-deep` with 15% `--navy` |

### Derivation recipes

Every non-authored token is a `color-mix(in srgb, A p%, B)` of two authored
tokens, or of one against `transparent` (alpha over the theme
background). For example:

```css
--bg: color-mix(in srgb, var(--navy) 4%, var(--paper));
--gold-deep: color-mix(in srgb, var(--gold) 50%, var(--navy-deep));
--accent-soft: color-mix(in srgb, var(--gold-deep) 12%, transparent);
```

A gray in this system is always a mix or translucent treatment of `--navy`
or `--gold` with `--paper`, never a separate neutral value.

### Contrast pairs

This table is checker output, not hand-written: it is regenerated from
`ruby scripts/color_check.rb site --tokens site/src/styles.css --json`
(WCAG 2.2 SC 1.4.3: 4.5:1 body text, 3:1 large text and UI). CI does not run
it, because the checker needs Chromium in Docker; run it locally after any
token change and paste the new ratios here.

The `--page-*`, `--body-text`, `--code-bg-text`, `--tag-bg-text`, and `--surface*-text` tokens are
measurement aliases (`var()` references to the role tokens in parentheses)
that expose each pair to the checker; components never use them.

| Pair | Light | Dark |
|---|---|---|
| `--gold-btn-text` on `--gold-btn` | 9.38:1 | 9.38:1 |
| `--body-text` (`--text`) on `--background` (`--bg`) | 12.64:1 | 13.09:1 |
| `--page-heading-text` (`--heading`) on `--background` | 12.64:1 | 15.87:1 |
| `--page-link-text` (`--link`) on `--background` | 12.64:1 | 9.38:1 |
| `--page-link-hover-text` (`--link-hover`) on `--background` | 4.98:1 | 9.99:1 |
| `--page-accent-text` (`--accent`) on `--background` | 4.98:1 | 9.38:1 |
| `--page-muted-text` (`--muted`) on `--background` | 4.92:1 | 8.49:1 |
| `--code-bg-text` (`--muted`) on `--code-bg` | 4.83:1 | 8.22:1 |
| `--tag-bg-text` (`--muted`) on `--tag-bg` | 4.56:1 | 5.97:1 |
| `--surface-text` (`--muted`) on `--surface` | 5.2:1 | 6.81:1 |
| `--surface-hover-text` (`--muted`) on `--surface-hover` | 4.74:1 | 5.58:1 |

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
  `--paper` with `color-mix`, checked in both themes.
- Do not introduce a fifth authored color without a stated reason (the
  sanctioned exception is a single `--error` token, if the site ever needs
  one).
- Do not use pure black or mix toward a white or black literal; the dark base is `--navy-deep`.
- Do not hardcode a hex value in a component; use the variables.
