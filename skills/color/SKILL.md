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

A repo that guards a `@media (prefers-color-scheme: dark)` block with
`:root:not([data-theme="light"])` alongside a `:root[data-theme="dark"])`
block may keep both, as long as both reassign the same four tokens rather than
introducing separate dark-only literals.

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

Every derived text role states its contrast pair in both themes: 4.5:1 for
body text, 3:1 for large text and UI components, per WCAG 2.2 SC 1.4.3.
`ruby ~/.claude/cf/bin/color_check.rb` parses the stylesheet with a CSS
tokenizer, builds a theme model and resolves each pair against it. A pair it
cannot resolve, or a context it will not merge, is listed as unresolved with
a reason, to be stated manually; `--strict` is unchanged by this (it exits 1
only for palette over target or any finding, never for contrast).
A text role is a custom property with a whole hyphen segment `text`, `fg`,
`foreground`, `ink`, `title` or `link` (for example `--foreground`,
`--color-fg-default`). A sheet with no recognized text role gets one
"no text-role tokens recognized" unresolved row instead of an empty table.

| Area | Supported | Reported as unsupported (with a reason, never guessed) |
|------|-----------|-------------------------------------------------------|
| Theme contexts | bare `:root`/`html` (base); `[data-theme=X]` or `.X` on `:root`/`html`, with optional `:not(...)`; bare `.X` or `[data-theme=X]` whose block is custom-property-only; `@media (prefers-color-scheme: light or dark)`; `@layer` | any other selector carrying a text role; other `@media`, `@supports`, `@container`, `@scope`; SCSS nesting; conflicting theme markers |
| Color values | hex 3/4/6/8; `rgb`/`rgba`, `hsl`/`hsla` in comma or space syntax; the 148 named colors; `transparent`; `!important` | `oklch`, `oklab`, `lab`, `lch`, `hwb`, `color()`; relative color syntax; `calc()` in channels; CSS-wide keywords |
| Value functions | `var()` with or without fallback; `color-mix(in srgb, ...)` with either or both percentages | `color-mix` in any other space; `light-dark()`; `currentColor` |
| Stray scan, CSS | declaration values (hex, color functions, named colors), `@apply` | selectors, `url()` fragments, strings inside values, the keywords `transparent`, `currentColor`, `inherit`, `initial`, `unset`, `revert`, `none` |
| Stray scan, markup and script | `style=`, `fill=`, `stroke=`, `class=`/`className=` attribute values; quoted strings that are exactly one color: any hex length when the value of a color-bearing key (`color`, `backgroundColor`, `borderColor`, `fill`, `stroke`, `shadow` and the like), otherwise only 6- or 8-digit hex, a color function or a named color | 3- or 4-digit hex strings outside a color-bearing key (`querySelector('#cafe')`), hex inside longer strings (`'/page#feed'`), ID selectors, `<style>` and `<script>` blocks, prose, text nodes, MDX code blocks, CSS-in-JS template literals as CSS, SCSS variables and mixins as tokens, standalone `.svg` files |

In both stray scan rows, a quoted string whose key context cannot be
determined (a short hex after a ternary `?`, for example) is listed as
unresolved, not exempt, and does not affect `--strict`. Any form named in
neither column is reported unresolved, never guessed.
`test/color_support_table_test.rb` holds one fixture per form in this table,
so the table and the checker cannot drift apart.

## Decision heuristic

Fewer colors, stronger relationships, more reuse. Four related colors used
many ways beats twenty tasteful ones.

## Procedure: audit, then fix

1. Run `ruby ~/.claude/cf/bin/color_check.rb <repo root> --json` (add
   `--tokens <path>` if detection picks the wrong file).
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
