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
never a fifth literal:

```css
:root {
  --cream: #f6efe0;
  --plum: #24122a;
  --lilac: #a070c8;
  --pink: #f2c4c4;

  --bg: var(--cream);
  --text: var(--plum);
  --accent: var(--lilac);

  --muted: color-mix(in srgb, var(--text) 60%, var(--bg));
  --border: color-mix(in srgb, var(--text) 18%, transparent);
  --divider: color-mix(in srgb, var(--text) 10%, transparent);
  --panel: color-mix(in srgb, var(--text) 4%, var(--bg));
  --hover: color-mix(in srgb, var(--accent) 12%, transparent);
  --disabled: color-mix(in srgb, var(--text) 35%, var(--bg));
  --scrim: color-mix(in srgb, var(--plum) 60%, transparent);
}

:root[data-theme="dark"] {
  --bg: var(--plum);
  --text: var(--cream);
  --accent: var(--lilac);
  --title: var(--pink);

  --muted: color-mix(in srgb, var(--text) 55%, var(--bg));
  --border: color-mix(in srgb, var(--text) 18%, transparent);
  --divider: color-mix(in srgb, var(--text) 10%, transparent);
  --panel: color-mix(in srgb, var(--text) 6%, var(--bg));
  --hover: color-mix(in srgb, var(--accent) 16%, transparent);
  --disabled: color-mix(in srgb, var(--text) 30%, var(--bg));
  --scrim: color-mix(in srgb, var(--cream) 50%, transparent);
}
```

## Contrast pairs

Light theme: `--text` (`#24122a`) on `--bg` (`#f6efe0`) resolves well above
4.5:1 for body text. `--accent` (`#a070c8`) on `--bg` is checked against 3:1
for focus rings and large text.

Dark theme: `--text` (`#f6efe0`) on `--bg` (`#24122a`) resolves well above
4.5:1. `--title` (`#f2c4c4`) on `--bg` is checked against 3:1 for large
titles, since it is not used for body text.

Run `ruby ~/.claude/cf/bin/color_check.rb <path> --json` to compute actual
ratios for a real token file; the numbers above are illustrative only.
