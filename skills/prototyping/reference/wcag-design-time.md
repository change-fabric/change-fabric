# WCAG 2.2 at design time

Policy: level AA is required, level AAA is advisory and never blocks. Error, focus, and 320px states are optional in a mock; a criterion that needs an absent state is `not evaluable`. Results use the format in `../SKILL.md`: `pass`, `issue (severity 0-4)`, or `not evaluable`.

Source: W3C, WCAG 2.2, https://www.w3.org/TR/WCAG22/ (criterion names used as labels; checks are own words).

## Checkable at design time

Settled from tokens and declared styles before any frame is rendered.

| Criterion | Level | Check |
|---|---|---|
| 1.4.3 Contrast (Minimum) | AA | Every text and background token pair reaches 4.5:1, or 3:1 for large text; audit the token file with cf:color |
| 1.4.11 Non-text Contrast | AA | Borders, focus rings, and control boundaries reach 3:1 against adjacent colors; checked through cf:color |
| 2.4.7 Focus Visible | AA | DESIGN.md and tokens.css declare a focus style for every interactive component |
| 2.5.8 Target Size (Minimum) | AA | Interactive targets are at least 24 by 24 CSS px, or spaced so a 24px circle fits |
| 1.4.12 Text Spacing | AA | Type tokens and layout intent tolerate increased line, paragraph, letter, and word spacing without clipping |

## Indicative on frames

Visible on rendered stills or recorded scenes, but a frame cannot prove them.

| Criterion | Level | Check |
|---|---|---|
| 1.4.1 Use of Color | A | Status and errors carry a word, icon, or shape besides color |
| 2.4.11 Focus Not Obscured (Minimum) | AA | A focused control is not hidden behind sticky headers, toasts, or overlays in the focus frames |
| 1.4.10 Reflow | AA | The 320px state, when present, shows no two-dimensional scrolling for text content |
| 3.3.2 Labels or Instructions | A | Every input has a visible label or instruction, not placeholder text alone |
| 2.4.6 Headings and Labels | AA | Headings and labels describe their section or control |
| 3.2.6 Consistent Help | A | Help, when offered, sits in the same place on every screen |
| 3.3.7 Redundant Entry | A | A flow does not ask again for data already entered in the same session |
| 3.3.8 Accessible Authentication (Minimum) | AA | Sign-in does not depend on a cognitive test such as recalling or transcribing a code without paste or a password manager |
| 2.5.7 Dragging Movements | AA | Every drag interaction has a single-pointer alternative shown on screen |

## Not checkable, deferred to cf:a11y

These need real markup, behavior, or assistive technology. Mark them `not evaluable` on a mock and defer to cf:a11y against the built product.

| Criterion | Level | Why deferred |
|---|---|---|
| 2.1.1 Keyboard | A | Needs real keyboard operation of every control |
| 2.4.3 Focus Order | A | Needs the real DOM and tab sequence |
| 4.1.2 Name, Role, Value | A | Needs the real accessibility tree |
| 1.3.1 Info and Relationships | A | Needs real semantic structure |
| 1.1.1 Non-text Content | A | Needs real text alternatives in the shipped markup |
| 3.1.1 Language of Page | A | Needs the shipped document language |
| 4.1.3 Status Messages | AA | Needs real live regions announced by assistive technology |
| 2.2.x Enough Time | A to AAA | Needs real timeouts and session behavior |
| 1.4.4 Resize Text | AA | Needs the real layout under 200 percent zoom |
