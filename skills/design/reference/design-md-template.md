# DESIGN.md template

The section outline cf:design writes. `design_tokens.rb lint` requires every level-two heading below, in any order. Lines from Principles through Do and do not need a provenance tag; Problem and users and Open questions do not.

Provenance tags, one per content line:

- `[evidence: prd.md#goals]` source path, a `#`, then the heading or line anchor
- `[assumption]` the evidence does not settle it
- `[proposal]` an opinion this run brings to bear

````markdown
# <Product> design system

## Problem and users

Who uses this, in what situation, and what they need to get done.

## Principles

1. Calm over clever: one accent per screen. [proposal]
2. Shift leads scan, they do not read. [evidence: prd.md#personas]

## Tokens

| Role | Token | Light | Dark |
|---|---|---|---|
| Page | `--bg` | A subtle | B primary [proposal] |
| Card | `--surface` | white mix | B subtle [proposal] |
| Body text | `--text` | B primary | A subtle [proposal] |
| Action | `--btn` | A primary | A primary [evidence: brand.pdf#color] |

```css
--bg: #f7f5f0;
--text: #1c2430;
```

Every declaration in a css fence appears verbatim in tokens.css. [proposal]

## Typography

Body, heading, and mono stacks, sizes, line heights. [proposal]

## Spacing and layout

The spacing scale, radius, grid, and breakpoints. [proposal]

## Themes

How light and dark reassign roles among the same authored colors. [proposal]

## Accessibility commitments

AA contrast for every text pair, 24px minimum targets, a visible focus ring. [evidence: wcag-design-time.md#contrast]

Contrast pairs pasted from `color_check.rb --json` output: [evidence: tokens.css#root]

```
light --text on --bg 14.1 pass
```

## Components

Buttons, inputs, cards, tables: each with its states. [proposal]

## Do and do not

Do keep one primary action per view. [proposal]
Do not add a fifth authored color without a stated reason. [evidence: cf:color#favor]

## Open questions

Calls left for a later round or a stakeholder.
````
