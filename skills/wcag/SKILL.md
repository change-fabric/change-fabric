---
name: cf:wcag
group: rubrics
description: WCAG 2.2 accessibility rubric for designs, plans, and UI code, split into what can be checked at design time, what frames indicate, and what needs the built product. Auto-applied by the cf shim on UI markup and component changes; also invocable directly.
auto:
  extensions: [html, htm, jsx, tsx, vue, svelte, erb]
lens:
  keywords: [screen, page, form, UI, component, accessibility, WCAG, keyboard, contrast, ARIA]
---

# WCAG 2.2

Source: W3C, Web Content Accessibility Guidelines (WCAG) 2.2, https://www.w3.org/TR/WCAG22/. Criterion names are used as labels; the checks are our own words. Read the standard for the authoritative text.

This is the single home for the design-time WCAG subset. cf:prototyping, cf:design, and cf:prototype point here; cf:a11y runs axe-core against built pages and is the lane for what a rubric cannot settle.

Policy: level AA is required, level AAA is advisory and never blocks. Error, focus, and 320px states are optional in a mock; a criterion that needs an absent state is `not evaluable`. Results are `pass`, `issue (severity 0-4)`, or `not evaluable`.

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

## In code

When the change is markup or a component, also check what the tables defer:

- native elements first (`button`, `a`, `label`, `input`); ARIA only where no native element fits, and never a role that contradicts the element
- every control reachable and operable by keyboard, in a sensible order, with a visible focus style
- every image and icon-only control has a text alternative; decorative images are hidden from assistive technology
- headings form an outline; landmarks mark the main regions
- status changes that matter are announced through a live region
- the page declares its language

## Planning checks

Apply these to a plan or design doc before code exists:

1. Each new screen, page, or form names its keyboard path and focus order.
2. The color tokens the plan adds are named with their contrast pairs.
3. Every form field has a visible label and a stated error message pattern that does not rely on color alone.
4. Sign-in and verification steps allow paste and password managers.
5. Drag, swipe, or hover-only interactions have a stated single-pointer alternative.
6. The plan says where cf:a11y runs against the built pages before release.

## Agent protocol

1. Classify each finding by the three tables; never fail a mock on a deferred criterion.
2. Report AA issues as required and AAA as advisory.
3. Prefer native semantics over ARIA fixes.
