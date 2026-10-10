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
(Ruby 3.2 or newer, Docker required) reads the pairs from the token file and
resolves each one per variant through a real browser. A pair whose color the
browser could not compute in a variant is listed as unresolved with a
reason, to be stated manually; an unresolved pair never fails `--strict`,
but a resolved pair that fails contrast does.

## How it reads the file

The checker does not parse CSS itself. It hands the token file to a pinned
headless Chromium (Docker required; there is no non-Docker path) and reports
whatever the browser computes, so any CSS the browser accepts is accepted:
cascade layers, `!important`, specificity, escapes, nesting and every color
function the browser supports all resolve exactly as they do on a real page.

The file is found by this path list, relative to the scan root, in order:
`app/globals.css`, `src/app/globals.css`, `app/styles/tokens.css`,
`src/styles/tokens.css`, `styles/tokens.css`, `src/styles/globals.css`,
`styles/globals.css`, `src/index.css`, `app/assets/stylesheets/tokens.css`,
`tokens.css`. `--tokens <path>` overrides it; a relative `--tokens` path
resolves against the current directory, not the scan root. Zero matches or
several matches is an error naming the candidates.

When the file's text mentions `@import`, `@theme`, `@tailwind`, `@apply`,
`@source`, `@plugin`, `@config`, `@custom-variant`, `@utility`, `@variant` or
`@reference`, the checker first compiles it with the repo's own installed
Tailwind (reading the version from `node_modules/tailwindcss`), inside the
same kind of pinned, throwaway container the browser runs in, mounting the
repo read-only and an empty directory as the build's working directory, so
Tailwind's automatic source scanning finds nothing. Anything the CLI would
otherwise find by default in that empty directory is passed explicitly: for
Tailwind 3, the first `tailwind.config.{js,cjs,mjs,ts,cts,mts}` at the scan
root goes in with `-c`, and an `@config` in the CSS still wins. Tailwind 4
reads a config only through `@config`, so it gets nothing extra. `@theme static`
variables are always emitted; a variable in a non-static `@theme` that no
utility uses is tree-shaken by the compile and never audited (see Known
limits). The compiled CSS, not the source file, is what the browser then
reads. That directive list is an advisory text heuristic for routing only:
the browser, not the list, decides what the CSS means.

What still errors:

- the file is not found, or several candidate files are found
- the token file cannot be read (missing, a directory, or unreadable)
- the file needs Tailwind but the repo has no `node_modules/tailwindcss` to
  compile it with
- the Tailwind build itself fails (the error carries the build tool's own
  message)
- the browser's CSSOM still contains an unresolved `@import` after compiling
  (an import nothing could bundle); audit that file directly instead
- the three dark mechanisms (the `.dark` class, the `data-theme` attribute,
  `prefers-color-scheme: dark` media) disagree with each other once each is
  tested alone; the error names the two mechanisms and the first name they
  differ on
- Docker is not available at all
- `node_modules/tailwindcss/package.json` carries a version that is not a
  plain semver version
- a `--tokens` file outside the scan root needs a Tailwind compile
- any unexpected checker or browser failure (reported as `could not audit: ...`,
  never raised)

A mechanism counts as "in use" only when its resulting palette differs from
light's. With one or none in use there is no disagreement to check. With
several in use, each is evaluated alone (the way a browser actually
activates them, one at a time) and all must land on the same palette, or
there is no single dark palette to grade.

A pair is unresolved, with a reason, rather than an error, when the browser
computed no color for one of its names in that variant ("is not a color in
dark"), or when the name was never declared at all anywhere in the file
("is not declared"). An unresolved pair is listed for the user to state
manually; it never fails `--strict`.

A declaration the browser rejects (an invalid value, a malformed `var()`)
does not exist for the checker and is never reported as an error: a pair
that needs it reports "is not declared", and a rejected `--x-text` forms no
pair at all.

## Known limits

These are by design. A review finding that matches one is answered with a
pointer here, not a fix.

- A literal mixed with a relative color built from a token
  (`color-mix(in srgb, rgb(from var(--a) r g b / .5), blue)`) is counted as
  derived.
- Several literals in one mix count as one blended color.
- `rgb(from var(--a) 0 0 0)` is derived, though every channel is fixed.
- `@property` `initial-value` literals are never read (the CSSOM rule has no
  style to walk).
- A literal inside a mix counts at full opacity; a fully transparent literal
  is not a color; a tint toward white or black is authored.
- A declaration the browser rejects does not exist for the checker; it is
  never reported as an error.
- Tailwind routing is a text heuristic; a directive inside a string can
  route a file to a compile, or to the "install dependencies" error when
  Tailwind is absent.
- A non-UTF-8 `@charset` is unsupported; the file is decoded as UTF-8.
- Unused non-static Tailwind `@theme` colors are not audited
  ([#247](https://github.com/change-fabric/change-fabric/issues/247)).
- A `--tokens` file outside the scan root cannot be compiled; pass a root
  that contains it.

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
