# Example palette

This is an example, not universal. Pick four colors per product, not these
four.

Two conceptual colors, two variants each: a neutral pair (cream, plum) and an
accent pair (lilac, pink).

| Token | Value | Light role | Dark role |
|---|---|---|---|
| `--cream` | `#f6efe0` | background | text |
| `--plum` | `#24122a` | text, titles, links, primary buttons | background |
| `--lilac` | `#a070c8` | focus ring, accent | links, focus ring, primary buttons |
| `--pink` | `#f2c4c4` | not used | titles |

Light mode: cream background, plum text and primary actions, lilac for focus
rings and accents. Dark mode: plum background, cream text, lilac for links and
primary actions, pink for titles. Same four tokens, roles reassigned.

## Derived tokens

Every other color in the system derives from these four by mixing or alpha,
rather than a fifth literal:

```css
:root {
  --cream: #f6efe0;
  --plum: #24122a;
  --lilac: #a070c8;
  --pink: #f2c4c4;

  --background: var(--cream);
  --page-text: var(--plum);
  --accent-ink: var(--lilac);
  --title-text: var(--plum);

  --muted: color-mix(in srgb, var(--page-text) 60%, var(--background));
  --border: color-mix(in srgb, var(--page-text) 18%, transparent);
  --divider: color-mix(in srgb, var(--page-text) 10%, transparent);
  --panel: color-mix(in srgb, var(--page-text) 4%, var(--background));
  --hover: color-mix(in srgb, var(--accent-ink) 12%, transparent);
  --disabled: color-mix(in srgb, var(--page-text) 35%, var(--background));
  --scrim: color-mix(in srgb, var(--plum) 60%, transparent);
}

:root[data-theme="dark"] {
  --background: var(--plum);
  --page-text: var(--cream);
  --accent-ink: var(--lilac);
  --title-text: var(--pink);

  --muted: color-mix(in srgb, var(--page-text) 55%, var(--background));
  --border: color-mix(in srgb, var(--page-text) 18%, transparent);
  --divider: color-mix(in srgb, var(--page-text) 10%, transparent);
  --panel: color-mix(in srgb, var(--page-text) 6%, var(--background));
  --hover: color-mix(in srgb, var(--accent-ink) 16%, transparent);
  --disabled: color-mix(in srgb, var(--page-text) 30%, var(--background));
  --scrim: color-mix(in srgb, var(--cream) 50%, transparent);
}
```

## Contrast pairs

Each foreground is named `--<x>-text` or `--<x>-ink` with no `--<x>` token
declared, so the checker pairs it with `--background` in both themes.

Light theme: `--page-text` (`#24122a`) on `--background` (`#f6efe0`) resolves
well above 4.5:1 for body text. `--accent-ink` (`#a070c8`) on `--background`
is checked against 3:1 for focus rings and large text.

Dark theme: `--page-text` (`#f6efe0`) on `--background` (`#24122a`) resolves
well above 4.5:1. `--title-text` (`#f2c4c4`) on `--background` is checked
against 3:1 for large titles, since it is not used for body text.

Run `ruby ~/.claude/cf/bin/color_check.rb <path> --json` to compute actual
ratios for a real token file; the numbers above are illustrative only.
