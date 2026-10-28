---
name: cf:prototype
group: workflow
description: Static HTML/CSS mock-screen command. Reads DESIGN.md and tokens.css, authors one HTML file per screen state using only those tokens, Phosphor icons for UI, Simple Icons for brand logos, and gpt-image-2 for in-screen imagery, with realistic client-side state from a shared vanilla JS mock store seeded from data/seed.json. Renders a still per screen, then records scripted mouse and keyboard motion as PNG frames under a controlled clock in the pinned browserless container. Usable alone (screens plus stills) or composed by cf:walkthrough.
---

# CF prototype

Source: Stephanie Houde and Charles Hill, "What do Prototypes Prototype?" (1997), via cf:prototyping; Jakob Nielsen, ten usability heuristics (1994), via cf:usability.

Load cf:prototyping and cf:usability by name before authoring anything. cf:prototyping says which design question each screen answers and at what fidelity; cf:usability is the rubric every recorded scene is evaluated against. This skill carries no heuristic checklist of its own.

## Inputs

1. `DESIGN.md` and `tokens.css` at the target repo root. With neither, run cf:design first.
2. A PRD, brief, or a `walkthrough/<slug>/storyboard.json` naming the screens and their states.

Everything lands in `walkthrough/<slug>/` in the target repo (layout below).

## Screens

- One HTML file per screen state: `screens/<scene-id>.html`. Static HTML and CSS, authored by hand from the tokens. No AI-generated UI and no screenshot-of-a-UI images.
- Link `tokens.css` (copied into `screens/`) and use only its custom properties for color, type, spacing, radius, focus, and motion. A hard-coded color or font is a defect.
- Local assets only. A remote `http(s)` reference, `<video>`, `<canvas>`, `<iframe>`, or Lottie fails capture with `UnsupportedContentError`, by design. Fonts are local files.
- Fictional data only, each invented record and feature recorded in `ASSUMPTIONS.md`. Nothing about the prototype status appears on screen.

## Mock state (core tenet)

Screens feel real because state is real. Copy `reference/mock-store.js` into `screens/mock-store.js` and seed it from `data/seed.json` (fictional records).

- `CFStore.get/set/push/remove/subscribe/nextId/dump`, persisted to `localStorage` under `cf-mock`, or memory when storage is unavailable.
- `<form data-cf-submit="list">` pushes its fields onto a list; `<template data-cf-list="list">` with `[data-cf-field]` renders rows; `[data-cf-count]` and `[data-cf-empty]` follow list length; `data-cf-toast` reveals a success element.
- During capture the seed arrives as `window.__CF_SEED__`. Opened by hand, a screen reads an inline `<script type="application/json" id="cf-seed">` copy of the seed.
- Forbidden: frameworks, build steps, `fetch`, XHR, WebSocket, IndexedDB, backends, and real integrations. A network request or IndexedDB access fails the capture.

An action in one scene can change what a later scene shows: the later scene names `store.from_scene`, and capture starts it from that scene's recorded `end-state.json`.

## Icons and imagery

- Avoid the generic AI-look defaults in cf:design's `reference/banned-defaults.md` (dated, reviewable) unless DESIGN.md chooses one on purpose.
- UI icons: Phosphor, `ruby ~/.claude/cf/bin/prototype_icons.rb walkthrough/<slug>/.cache/icons` fetches the pinned tarballs (sha512 checked, no fallback). Copy only used SVGs into `screens/assets/icons/` with `PrototypeIcons.copy_used`.
- Brand logos: any Simple Icons logo, including plausible integrations. Record each in `ASSUMPTIONS.md` with its `guidelines` link and `license` field, and drop any logo whose guidelines forbid the use.
- Write `THIRD_PARTY_NOTICES` from `PrototypeIcons.notices` (Phosphor MIT notice, Simple Icons CC0 plus trademark disclaimer).
- Imagery (avatars, product photos, hero art): `prototype_imagegen.rb`, model `CF_IMAGE_MODEL` (default `gpt-image-2`), `medium` for drafts and `high` for finals, cap of 3 attempts per screen. Print the cost estimate before any paid call. Outputs are cached by content hash under `.cache/images/`; a cached run needs no key. `OPENAI_API_KEY` comes from env or `CF_SECRETS_ENV`; never print it.

## Render and record

All browser work runs in the pinned browserless container via `ChangeDocker.with_browserless` and `BrowserlessJs`. No host browser, no Playwright, no screencast.

1. Stills first: `ruby ~/.claude/cf/bin/prototype_capture.rb walkthrough/<slug>/storyboard.json --still` writes `.cache/stills/<scene-id>/000001.png`. Review each still against cf:usability and the cf:prototyping WCAG subset, and fix screens before recording motion.
2. Motion: the same command without `--still` (optionally `--scene <id>`) records each scene whose `frames_key` is not cached. 30 fps; the clock only advances per frame; CSS animations are paused and seeked to virtual time; `Math.random` and `crypto.randomUUID` come from a seeded PRNG; storage is cleared per scene; input is real `page.mouse` and `page.keyboard` events.
3. Outputs per scene in `.cache/frames/<frames_key>/`: `NNNNNN.png`, `cursor.json` (`[{frame, x, y, down}]`, composited later by FFmpeg), and `end-state.json`.
4. Evaluate each recorded scene with cf:usability and note findings against the scene.

Without a storyboard, write a minimal one (one scene per screen, no interactions) to get stills.

## Layout

```
walkthrough/<slug>/
  screens/<scene-id>.html  screens/tokens.css  screens/mock-store.js  screens/assets/
  data/seed.json  ASSUMPTIONS.md  THIRD_PARTY_NOTICES  .gitignore (.cache/)
  .cache/  icons/  images/  stills/  frames/<frames_key>/
```

## Done when

- Every screen uses tokens only, local assets only, and passes the stills review.
- Every invented record, feature, and logo is in `ASSUMPTIONS.md`; `THIRD_PARTY_NOTICES` covers every icon set used.
- Recorded scenes exist for every storyboard scene, and cross-scene state flows through `from_scene`.
