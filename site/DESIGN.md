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

Two colors plus neutrals. The source of truth is the CSS custom properties in
`src/styles.css`; the values below are the intent behind them.

- Navy: the dark theme's background and, in the light theme, the color of
  headings, the wordmark, nav, and link text.
- Gold: the accent in both themes. Real gold/amber, never a garish yellow.
  Links (dark theme), hovers, badges, the version tag, card hover borders, the
  external-link arrow, and CTA buttons.
- Neutrals: near-white and blue-grays for body text and muted secondary text.

Rule of thumb: gold is for the one thing you want the eye to go to in a given
area, not for large fills. Navy anchors; gold points.

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

When adding a color, add it as a variable in all three places, not as a literal.

## Icons

Phosphor Icons (phosphoricons.com, MIT), regular weight, inlined as SVG with
`fill="currentColor"` so they inherit the theme. The favicon is the Phosphor
crosshair (a precision/quality-gate motif): gold glyph on a navy rounded tile.

## Do and do not

- Do keep gold scarce and intentional; do keep navy as the anchor.
- Do add new colors as theme variables, checked in both themes.
- Do not introduce a third brand color or a second accent.
- Do not use pure black; the dark base is navy.
- Do not hardcode a hex value in a component; use the variables.
