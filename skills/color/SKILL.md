---
name: cf:color
description: Minimal color system command. Audits a repo's palette, stray color literals, Tailwind palette classes and gradients against a four-color target with role-reassigned themes and derived colors, then consolidates as far as the user approves. Opt-in, invoked only when deliberately driving a color outcome.
---

# CF color

Applies only when invoked. A larger palette is not wrong; this is a tool for
driving toward a minimal, coherent color system when color is the thing being
worked on, not a universal standard every app must meet.

Source: the minimal color system notes and WCAG 2.2 SC 1.4.3.

Question: could this UI be drawn with about four related colors used many
ways?

## Favor and avoid

Favor, when driving toward the minimal system:

- about four authored colors: two conceptual colors, two variants each (A
  primary plus A subtle, B primary plus B subtle)
- one canonical token file of semantic CSS variables
- themes built by reassigning roles among the same tokens
- deriving secondary colors from the palette by mixing or alpha
- asking whether a mix or alpha over an existing token does the job before
  adding a literal
- palette tokens over generic slate, zinc, gray or blue utility classes
- typography, spacing, hierarchy, shape and composition over decorative
  gradients
- when reviewing an existing app, identifying independent colors and
  consolidating as far as the user approves

Avoid, when driving toward the minimal system: one-off hex, rgb, hsl or
Tailwind palette literals in components; arbitrary grays and near-blacks;
blue-gray borders; generic framework accent colors; decorative gradients; a
fifth canonical color with no stated reason.

## Themes by role reassignment

Light and dark mode reassign roles among the same palette rather than adding
new colors. A light neutral may be the background in light mode and the text
color in dark mode; a dark color may be text in light mode and background in
dark mode; a subtle variant may become the primary accent in dark mode. All
four tokens may appear in either mode, just in different roles.

A token file may spell dark several ways (`.dark`, `[data-theme=dark]`, an
`@media (prefers-color-scheme: dark)` block around `:root`), as long as every
dark block reassigns names light already declares, with identical values.

## Derived colors

Muted text, borders, dividers, panels, cards, code blocks, bubbles, hover
states, disabled states, scrims and subtle backgrounds all derive from the
four authored tokens via alpha or mixing, rather than a fifth design color:

```css
--muted: color-mix(in srgb, var(--a) 60%, var(--b));
--border: color-mix(in srgb, var(--a) 12%, transparent);
```

A gray in this system is a mixture or translucent treatment of palette
colors, not a fifth authored color. This keeps the result coherent and
art-directed instead of accumulating the generic look of arbitrary grays,
blue-gray borders, and one-off component colors.

## The error color

Exactly one documented semantic error color is the sanctioned exception,
named `--error`. The checker recognizes only that name; any other extra
authored color beyond the four-color target is reported as beyond target and
needs a stated reason.

## Contrast

Pairs come from a fixed naming rule, with no new syntax: a token
`--x-<suffix>` with suffix in `text`, `fg`, `foreground`, `ink` pairs with
`--x` when `--x` is declared, else with `--background`. Every pair is checked
in light and in dark, against 4.5:1 for body text and 3:1 for large text and
UI components, per WCAG 2.2 SC 1.4.3. `ruby ~/.claude/cf/bin/color_check.rb`
reads the pairs from the token file and resolves `var()` and
`color-mix(in srgb, ...)` per variant. A pair whose value it cannot resolve
(`oklch(...)`, for example) is listed as unresolved with a reason, to be
stated manually; contrast never fails `--strict`.

### Token file

The palette is declared in one token file of a fixed shape. The checker reads
only that file, strictly; anything else in it is an error, printed with the
line number and the construct named. Token-file errors always print and fail
`--strict`. There is no cascade, layer or selector modelling.

The file is found by this path list, relative to the scan root, in order:
`app/globals.css`, `src/app/globals.css`, `app/styles/tokens.css`,
`src/styles/tokens.css`, `styles/tokens.css`, `src/styles/globals.css`,
`styles/globals.css`, `src/index.css`, `app/assets/stylesheets/tokens.css`,
`tokens.css`. `--tokens <path>` overrides it. Zero matches or several matches
is an error naming the candidates.

Accepted shape:

- Top level: rule blocks; `@media (prefers-color-scheme: dark)` and
  `@media (prefers-color-scheme: light)` blocks holding only rule blocks; at
  most one transparent `@layer` wrapper (named or anonymous) around any of
  these. A nested `@layer` is an error. The statements `@import`, `@charset`,
  `@tailwind`, `@source`, `@plugin`, `@custom-variant` and `@config` are
  skipped. `@theme` blocks follow the `:root` light rules. Any other at-rule
  is an error.
- Selectors: `:root` (light); `.dark`, `:root.dark`, `[data-theme=dark]` in
  any quote style, and `:root[data-theme=dark]` (dark). A selector list is
  accepted only when every member is in the same variant. `html` is not
  accepted. Any descendant, child or sibling combinator (`:root .dark`,
  `.dark .card`) is an error.
- Inside `@media (prefers-color-scheme: dark)` only `:root` is accepted, and
  it means dark. Inside `@media (prefers-color-scheme: light)` only `:root`,
  merged with light; a conflicting value is an error.
- Declarations: only `--name: value`. A normal property or `@apply` is an
  error.
- Values: hex, `rgb`/`rgba`, `hsl`/`hsla` and named colors are authored
  colors and count toward the palette size. `var(--x)` and
  `color-mix(in srgb, ...)` are derived and resolved. A non-color value
  (`--radius: 0.5rem`) is ignored. A color-shaped value the resolver does not
  support (`oklch(...)`) is unresolved for contrast, not an error.
- Dark may only redefine names light declares; a new name in dark is an
  error. Two dark blocks giving one name different values is an error.

### Stray scan

Every color literal or palette class outside the token file is a stray.

Surfaces: every CSS file except the token file (declaration values and
`@apply` preludes); in markup, `<style>` blocks (as CSS), `style=` attributes
(as declarations), `fill=` and `stroke=` values (whole value a color literal),
`class=` and `className=` values (Tailwind rule below); `<script>` blocks and
JS/TS files, where a quoted string is a finding only when the whole string is
a hex color or an `rgb()`, `rgba()`, `hsl()` or `hsla()` call.

Literal forms: hex, the `rgb()`/`hsl()` family, and named colors in
color-accepting properties (a named color in an unknown property is
unresolved). Exempt: `transparent`, `currentColor`, `inherit`, `initial`,
`unset`, `revert`, `none`.

Tailwind rule, for `class`/`className` values and `@apply` preludes only:
split on whitespace; strip `!`, variant prefixes (`hover:`, `md:dark:`) and a
trailing `/<opacity>`; match the longest color prefix (`bg`, `text`,
`border` and its sides, `ring`, `ring-offset`, `outline`, `divide`,
`shadow`, `inset-shadow`, `inset-ring`, `drop-shadow`, `from`, `via`, `to`,
`fill`, `stroke`, `decoration`, `accent`, `caret`, `placeholder`). The rest
is a finding when it is a palette `<hue>-<shade>`, `black`, `white`, or a
bracketed color literal (`bg-[#abc]`); `[var(--x)]` is exempt when `--x` is a
token, else unresolved; `current`, `transparent` and `inherit` are exempt;
known non-color words (`text-sm`, `border-2`) are skipped; any other word `w`
is exempt when `--w` is a token, else unresolved as an unknown Tailwind color
word. One finding per utility, its text the utility as written.

Unresolved stray entries print and never fail `--strict`.

Not scanned: JS strings that are not whole-string literals, template
literals, CSS-in-JS, Tailwind classes outside `class`/`className`/`@apply`
(`clsx` or `cva` arguments, and `className` strings inside .jsx/.tsx
files, which are script), SCSS variables, standalone `.svg` files, text
nodes.

`test/color_support_table_test.rb` holds one fixture per bullet in these two
sections, so the contract and the checker cannot drift apart.

### Review triage

A token-file construct outside the grammar is an error by design: the reply
cites the grammar and no code changes. Stray-scan input outside the listed
surfaces and forms is out of scope: dismiss as wont-fix with a link to the
section. A finding that shows the checker violating a stated rule is a bug
and is fixed.

## Decision heuristic

Fewer colors, stronger relationships, more reuse. Four related colors used
many ways beats twenty tasteful ones.

## Procedure: audit, then fix

1. Run `ruby ~/.claude/cf/bin/color_check.rb <repo root> --json` (add
   `--tokens <path>` when the token file is not on the path list).
2. Report neutrally: the current palette and its distance from the
   four-color target, stray literals, Tailwind palette classes, gradients,
   and the contrast table. Never call a larger palette a failure; the
   checker exits 0 by default regardless of what it finds, and non-zero only
   under `--strict`.
3. If there is no palette, propose four colors with light and dark role
   tables. If there is one, propose a consolidation map: each existing color
   mapped to a token or a derivation of one.
4. Ask via AskUserQuestion, per finding group, which consolidations to
   apply. The user may approve some groups and decline others, and may stop
   short of four colors.
5. Under away mode, report only and make no edits.
6. Apply the approved edits, re-run the checker, and report the new counts
   and contrast table.

## Example

`reference/example-palette.md` has a full example, cream, plum, lilac and
pink, with light and dark role tables and the derived-token recipe. Labelled
as an example, not universal:

| Token | Value | Light role | Dark role |
|---|---|---|---|
| `--cream` | `#f6efe0` | background | text |
| `--plum` | `#24122a` | text, titles, links, primary buttons | background |
| `--lilac` | `#a070c8` | focus ring, accent | links, focus ring, primary buttons |
| `--pink` | `#f2c4c4` | not used | titles |

## Related

- `cf:a11y` checks contrast in the default theme only; a dark-mode pass is
  still manual.
- `cf:qa` can run a manual theme-toggle pass as part of a broader smoke test.
- `cf:react` owns color literals inside React components; `cf:color` owns
  the palette they draw from.
- `cf:ai-slop` is related but separate: it governs prose, not color.
