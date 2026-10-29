# Harborline design system

## Problem and users

Commuters board the same ferry most mornings and want to rebook in one tap, often one handed on a moving pier.

## Principles

Speed over browsing: the saved trip is the first thing on the home screen. [evidence: prd.md#saved-trips]
One primary action per screen. [proposal]
State the price before the commuter commits. [evidence: prd.md#rebooking]

## Tokens

Every value below is quoted verbatim from tokens.css. [proposal]

```css
--bg: #f4f7fa;
--surface: #ffffff;
--text: #0e1b26;
--muted: #4a5a68;
--accent: #0b5a8a;
--accent-text: #ffffff;
--border: #d3dbe2;
--focus: #0b5a8a;
```

## Typography

One system font stack at an 18px body and a 34px title. [evidence: conventions.md#harborline-conventions]

```css
--font: system-ui, sans-serif;
--size-body: 18px;
--size-title: 34px;
```

## Spacing and layout

An 8px base step with four sizes, and an 8px radius on every surface. [proposal]

```css
--space-1: 8px;
--space-2: 16px;
--space-3: 24px;
--space-4: 40px;
--radius: 8px;
```

## Themes

Light theme only for this release; dark is an open question. [assumption]

## Accessibility commitments

Text and the accent meet WCAG 2.2 AA contrast on the surface. [proposal]
Focus shows a 3px outline in the focus token, never removed. [proposal]
Targets are at least 44px tall for one handed use. [proposal]

## Components

Saved trip card: route, departure time, price, and one rebook button. [evidence: prd.md#saved-trips]
Success banner: role status, names the trip and time booked. [evidence: prd.md#rebooking]

## Do and do not

Do keep the wordmark on the accent background. [evidence: conventions.md#harborline-conventions]
Do not add a second accent color for promotions. [proposal]

## Open questions

Whether dark theme ships with saved trips or after.
