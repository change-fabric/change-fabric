---
name: cf:prototype
group: workflow
description: Static HTML/CSS mock-screen command. Reads DESIGN.md and tokens.css, authors one HTML file per screen state using only those tokens, Phosphor icons for UI, Simple Icons for brand logos, and gpt-image-2 for in-screen imagery, with realistic client-side state from a shared vanilla JS mock store seeded from data/seed.json. Renders a still per screen, then records scripted mouse and keyboard motion as PNG frames under a controlled clock in the pinned browserless container. Usable alone (screens plus stills) or composed by cf:walkthrough.
---

# CF prototype

Source: Stephanie Houde and Charles Hill, "What do Prototypes Prototype?" (1997), via cf:prototyping; Jakob Nielsen, ten usability heuristics (1994), via cf:usability.

Load cf:prototyping, cf:usability, and cf:fractal by name before authoring anything. cf:prototyping says which design question each screen answers and at what fidelity; cf:usability is the rubric every recorded scene is evaluated against. cf:fractal says to build every screen from the same few modules on one grid unit and scale ratio. This skill carries no heuristic checklist of its own.

## Inputs

1. `DESIGN.md` and `tokens.css` at the target repo root. With neither, run cf:design first.
2. A PRD, brief, or a `walkthrough/<slug>/storyboard.json` naming the screens and their states.

Everything lands in `walkthrough/<slug>/` in the target repo (layout below).

## Screens

- One HTML file per screen state: `screens/<scene-id>.html`. Static HTML and CSS, authored by hand from the tokens. No AI-generated UI and no screenshot-of-a-UI images.
- Link `tokens.css` (copied into `screens/`) and use only its custom properties for color, type, spacing, radius, focus, and motion. A hard-coded color or font is a defect.
- Local assets only. A remote `http(s)` reference, `<video>`, `<canvas>`, `<iframe>`, or Lottie fails capture with `UnsupportedContentError`, by design. Fonts are local files.
- Fictional data only, each invented record and feature recorded in `ASSUMPTIONS.md`. Nothing about the prototype status appears on screen.

## Desktop kit

A scene set on a computer (download an archive, extract it, edit a config file, install a service) uses the neutral desktop kit in `fixtures/desktop/` instead of a hand-built desktop: `"kind": "environment"` with a seed naming the windows (browser, file-explorer, text-editor, terminal, elevation-prompt, services-list) and their content. `ruby scripts/walkthrough_environment.rb storyboard.json` writes the screens; never edit them. The kit owns the chrome and fixed ids (`fixtures/desktop/CONTRACT.md`); the project owns names, file lists, config text, transcripts, and any vendor page shown in a browser window slot. The chrome stays generic: no lookalike of a real operating system.

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
- Imagery (avatars, product photos, hero art): use cf:image by name.

## Render and record

All browser work runs in the pinned browserless container via `ChangeDocker.with_browserless` and `BrowserlessJs`. No host browser, no Playwright, no screencast.

1. Stills first: `ruby ~/.claude/cf/bin/prototype_capture.rb walkthrough/<slug>/storyboard.json --still` writes `.cache/stills/<scene-id>/000001.png`. Review each still against cf:usability, cf:fractal, and the cf:prototyping WCAG subset, and fix screens before recording motion.
2. Motion: the same command without `--still` (optionally `--scene <id>`) records each scene whose `frames_key` is not cached. 30 fps; the clock only advances per frame; CSS animations are paused and seeked to virtual time; `Math.random` and `crypto.randomUUID` come from a seeded PRNG; storage is cleared per scene; input is real `page.mouse` and `page.keyboard` events.
3. Outputs per scene in `.cache/frames/<frames_key>/`: `NNNNNN.png`, `cursor.json` (`[{frame, x, y, down}]`, composited later by FFmpeg), `end-state.json`, and `ux-lint.json`.
   UX lint (free, every capture, `scripts/prototype_ux_lint.rb`): at scene start, middle, end, each scripted step, and each toast or sheet's first frame the page is checked for `empty-control` (a control, status, toast, or sheet with no accessible name or no rendered text; masked, transparent, and zero-size text does not count; an aria-labelled icon button up to 64px is fine), `occlusion` (elementFromPoint at a control's centre or corners hits something else; mark the page behind a modal `inert`), `clipped-text` (text clipped by its own overflow, or text or a control partly cut off by an ancestor's non-visible overflow, such as a button sliced by the phone edge; a scrolling list that peeks on purpose marks its container `data-ux-allow="clipped-text"`), `caption-safe` (a control or device frame reaching into the bottom 15% of the viewport, where players draw captions), `cursor-over-label`, and `contradictory-state` (a visible `[data-cf-success]` in a `[data-cf-state="pending"]` scope, or a `[data-cf-when="<states>"]` element shown in another state; `data-cf-for="<id>"` names a scope from outside it). Each report also records every device frame (`[data-cf-device]`, `.phone`, or `.device`) with its layout and rendered size, for cf:walkthrough's `device-frame` check. To enlarge a phone, scale the whole frame uniformly (`transform: scale`) and keep its CSS width, height, and bezel; never widen or reshape it. The cursor aims at a control's centre unless the sprite there would cover the label, then at the label's end padding, the bottom padding, or the icon. `data-ux-allow="<rule>"` opts an element out. Fix every finding before recording again; cf:walkthrough blocks `--final` on them.
4. Evaluate each recorded scene with cf:usability and note findings against the scene.
5. Optional: when the user wants a harsher outside read of the stills, load cf:roast by name (paid, never automatic).

## Flats (Figma-style stills)

Beyond the scenes in the video, output a "flats" folder: a still of every major screen in the product information architecture (from the PRD), including key states (empty, error, success), even screens the video never shows. Author `walkthrough/<slug>/flats.json`, the manifest that drives it, in flow order:

```json
{ "viewport": { "w": 1440, "h": 900 },
  "flats": [ { "section": "Loans", "screen": "List", "state": "empty", "html": "screens/loans-empty.html",
               "purpose": "First-run shelf with nothing lent", "goal": "Know what is out on loan",
               "requirements": ["TOOL-01"], "patch": [] } ] }
```

`purpose` and `goal` are required; `requirements` lists the PRD ids the screen covers; `patch` optionally reshapes the seeded mock state for that flat. Then run `ruby ~/.claude/cf/bin/prototype_flats.rb walkthrough/<slug>` (optionally `--manifest <path>`). Every flat renders in both themes (the `data-theme` attribute plus a `dark` class and `prefers-color-scheme` emulation, so whichever mechanism tokens.css uses applies), at device size and 2x:

```
flats/light/NN-section-screen[-state].png  and  @2x.png
flats/dark/NN-section-screen[-state].png   and  @2x.png
flats/light/overview.png  flats/dark/overview.png   (board, sections as rows in flow order)
flats/index.md   (TOC: overview links, then each IA section in flow order; per screen its state, purpose, user goal, PRD requirement ids, source HTML, and relative light and dark image links)
```

`flats/`, every MP4, and the overview PNGs are kept out of version control: the slug dir's ignore file holds `.cache/`, `flats/`, `*.mp4`, `overview*.png`, written by the toolkit.

Without a storyboard, write a minimal one (one scene per screen, no interactions) to get stills.

## Push to Figma (only when asked)

Never automatic. Push only on an explicit user request or `--push-figma`. If the Figma MCP is not connected or not authenticated, skip with one report line; never fail the run on it.

1. Load `/figma-use` and `/figma-generate-design`.
2. `create_session` for the target file (from the user's Figma URL, or `create_new_file` when they want a new one).
3. `upload_assets` for the stills and the flats PNGs (`flats/{light,dark}/*.png`).
4. `use_figma` to place each upload as a frame named after its flat (`NN-section-screen[-state]`).
5. Record the frame ids: `ruby ~/.claude/cf/bin/prototype_flats.rb record-figma --flats walkthrough/<slug>/flats.json --url <figma-url> --node <screen>=<node-id> ...`. This writes the `figma` block into `flats.json` (committed; ids are not secrets):

```json
{ "figma": { "url": "https://www.figma.com/design/AbCdEf123/Example-App", "file_key": "AbCdEf123",
  "frames": { "checkout-empty": "12:34" } } }
```

6. To diff a built app against those frames, `ruby ~/.claude/cf/bin/prototype_flats.rb routes-snippet --flats walkthrough/<slug>/flats.json [--route <screen>=/path ...] [--viewport desktop]` prints `routes[].figma` YAML for the browserless lane. A human pastes it into `CHANGE.md`; nothing writes it there automatically.

## Layout

```
walkthrough/<slug>/
  screens/<scene-id>.html  screens/tokens.css  screens/mock-store.js  screens/assets/
  data/seed.json  flats.json  ASSUMPTIONS.md  THIRD_PARTY_NOTICES  .gitignore (.cache/ flats/ *.mp4 overview*.png)
  flats/  index.md  light/  dark/  (generated, ignored)
  .cache/  icons/  images/  stills/  frames/<frames_key>/
```

## Done when

- Every screen uses tokens only, local assets only, and passes the stills review.
- Every invented record, feature, and logo is in `ASSUMPTIONS.md`; `THIRD_PARTY_NOTICES` covers every icon set used.
- `flats/` covers every IA screen and key state in both themes, with index.md and both overview boards.
- Recorded scenes exist for every storyboard scene, and cross-scene state flows through `from_scene`.
