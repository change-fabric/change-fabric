---
name: cf:color
description: Minimal color system command. Audits a repo's token file against a four-color target with role-reassigned light/dark themes and derived colors, then consolidates as far as the user approves. Opt-in, invoked only when deliberately driving a color outcome.
---

# CF color

Applies only when invoked. A larger palette is not wrong; this is a tool for
driving toward a minimal, coherent color system when color is the thing being
worked on, not a universal standard every app must meet.

Source: the minimal color system notes and WCAG 2.2 SC 1.4.3.

Question: could this UI be drawn with about four related colors used many
ways?

Stray color literals outside the token file (Tailwind palette classes, JS,
markup, MDX) are not scanned by this minimal skill; that is tracked in issue
#244.

## Favor and avoid

Favor, when driving toward the minimal system:

- about four authored colors: two conceptual colors, two variants each (A
  primary plus A subtle, B primary plus B subtle)
- one canonical token file of semantic CSS variables
- themes built by reassigning roles among the same tokens
- deriving secondary colors from the palette by mixing or alpha
- asking whether a mix or alpha over an existing token does the job before
  adding a literal
- when reviewing an existing app, identifying independent colors and
  consolidating as far as the user approves

Avoid, when driving toward the minimal system: a fifth canonical color with
no stated reason; arbitrary grays and near-blacks added to the token file
instead of derived from the palette.

## Themes by role reassignment

Light and dark mode reassign roles among the same palette rather than adding
new colors. A light neutral may be the background in light mode and the text
color in dark mode; a dark color may be text in light mode and background in
dark mode; a subtle variant may become the primary accent in dark mode. All
four tokens may appear in either mode, just in different roles.

A token file may spell dark several ways (`.dark`, `[data-theme=dark]`, an
`@media (prefers-color-scheme: dark)` block around `:root`), as long as every
dark block reassigns names light already declares, with identical values.
The media query, the `.dark` class and the `data-theme` attribute are three
independent activation mechanisms, so a file may use several only when each
one alone produces the same dark palette: repeat the same overrides under
each, never split them across mechanisms.

## Derived colors

Muted text, borders, dividers, panels, cards, hover states, disabled states,
scrims and subtle backgrounds all derive from the four authored tokens via
alpha or mixing, rather than a fifth design color:

```css
--muted: color-mix(in srgb, var(--a) 60%, var(--b));
--border: color-mix(in srgb, var(--a) 12%, transparent);
```

A gray in this system is a mixture or translucent treatment of palette
colors, not a fifth authored color.

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
(Ruby 3.2 or newer) reads the pairs from the token file and resolves `var()` references per
variant. A pair whose value it cannot resolve (`color-mix()` or `oklch(...)`,
for example) is listed as unresolved with a reason, to be
stated manually; an unresolved pair never fails `--strict`, but a resolved
pair that fails contrast does.

## Token file

The palette is declared in one token file of a fixed shape. The checker reads
only that file, strictly; anything else in it is an error, printed with the
line number and the construct named. Token-file errors always print and fail
`--strict`. The only cascade modelled is the CSS Cascade 5 sort between a
light and a dark declaration of one name: `!important` priority, then layer
origin, then selector specificity (`:root`, `.dark`, `[data-theme=dark]` and
the media `:root` are (0,1,0); `:root.dark` and `:root[data-theme=dark]` are
(0,2,0)), then source order, later winning. A dark block placed before an
equally specific `:root` loses to it.

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
  skipped. One `@theme` block (bare, or with `static`, `inline` or
  `default`) follows the `:root` light rules; a second `@theme` is an
  error, since Tailwind emits every one at the first one's position, and
  so is `@theme reference`, which emits no variables. Any other at-rule is
  an error.
- Selectors: `:root` (light); `.dark`, `:root.dark`, `[data-theme=dark]` in
  any quote style, and `:root[data-theme=dark]` (dark). A selector list is
  accepted only when every member is in the same variant. `html` is not
  accepted. Any descendant, child or sibling combinator (`:root .dark`,
  `.dark .card`) is an error.
- Inside `@media (prefers-color-scheme: dark)` only `:root` is accepted, and
  it means dark. Inside `@media (prefers-color-scheme: light)` only `:root`,
  merged with light; a conflicting value is an error, and so is a name only
  light media declares unless dark media also exists (otherwise light shows
  under a dark preference too, with that query inactive).
- Declarations: only `--name: value`. A normal property or `@apply` is an
  error.
- Values: hex, `rgb`/`rgba`, `hsl`/`hsla` and named colors are authored
  colors and count toward the palette size. `var(--x)` and
  `color-mix(in srgb, ...)` are derived; `var()` is resolved, `color-mix()`
  is not. A non-color value (`--radius: 0.5rem`) is ignored. A color-shaped
  value the resolver does not support (`color-mix()`, `oklch(...)`) is
  unresolved for contrast, not an error, so state its contrast manually. A
  `var()` whose first argument is not exactly one `--name` (whitespace and
  comments aside), such as `var(--b junk)`, even nested in a fallback, makes
  CSS ignore the whole declaration: it is an error and is never resolved.
- Dark may only redefine names light declares; a new name in dark is an
  error. Two dark blocks giving one name different values is an error.
  The dark palette is built once per activation mechanism in use
  (prefers-color-scheme media, the `.dark` class, the `data-theme`
  attribute), each alone over light through the cascade below; when those
  palettes differ it is an error naming both mechanisms and the first
  differing name.
  A normal dark value does not override an `!important` light one, so the
  light value stays in dark; an `!important` dark value overrides a normal
  light one. At equal priority layer origin decides: for normal declarations
  an unlayered value beats one inside the `@layer` wrapper, so a layered dark
  override does not replace an unlayered light value; for `!important` ones
  the order reverses. At equal rank dark wins. An equal-valued redeclaration
  keeps its highest-ranked origin. Values are equal when their tokens are,
  or when both are hex or color-function spellings of one color (`#FFF`,
  `#fff`, `rgb(255 255 255)`); a bare identifier such as `white` or `RED`
  compares exactly, since it may also be read as a name (an animation
  name), so `--a: white` then `--a: #fff` is a conflicting redeclaration.

### Supported values

The resolver that backs contrast and palette counting understands hex,
named colors, `rgb()`/`rgba()` and `hsl()`/`hsla()` with literal numeric or
percentage channels (legacy comma and modern space syntax, `/` or
comma-fourth-argument alpha), and a whole-value `var(--x)` or
`var(--x, fallback)` reference to another token, including a chain or a
cycle (reported unresolved, never a crash). Everything else a value can be
shaped like is unresolved, with a reason, rather than an error:
`color-mix()`, `oklch()`, `oklab()`, `lab()`, `lch()`, `hwb()`, `color()`,
a `var()` used inside a function's channel arguments instead of as the
whole value, a `none` channel, `calc()`, relative color syntax, and
`currentColor`/`light-dark()`/CSS-wide keywords. Every token is declared on
the root element, so a token set to `initial`, `inherit` or `unset` is the
guaranteed-invalid value: a `var()` to it takes its fallback, which is
graded, and with no fallback the pair is unresolved; `revert`,
`revert-layer` and `revert-rule` depend on the cascade and stay unresolved. An unresolved pair is
listed for the user to state manually; it never fails `--strict`, and
`--strict` only fails on a token-file error or an actually-resolved pair
that fails contrast.

## Decision heuristic

Fewer colors, stronger relationships, more reuse. Four related colors used
many ways beats twenty tasteful ones.

## Procedure: audit, then fix

1. Run `ruby ~/.claude/cf/bin/color_check.rb <repo root> --json` (add
   `--tokens <path>` when the token file is not on the path list).
2. Report neutrally: the current palette and its distance from the
   four-color target, the token-file errors, and the contrast table. Never
   call a larger palette a failure; the checker exits 0 by default
   regardless of what it finds, and non-zero only under `--strict`.
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
- `cf:ai-slop` is related but separate: it governs prose, not color.
