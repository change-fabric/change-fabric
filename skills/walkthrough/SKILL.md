---
name: cf:walkthrough
group: workflow
description: Flagship walkthrough command. Turns a PRD, SOW, brief, or an existing app into a cinematic narrated MP4 walkthrough without building the app, or films an already-built app from its URL, composing cf:design for DESIGN.md, cf:prototype for HTML/CSS mock screens and recorded motion, and cf:prototyping plus cf:usability for method and rubric. Writes storyboard.json as the source of truth, narrates in present tense as a shipped product, keeps the truth trail in an ASSUMPTIONS.md sidecar, generates ElevenLabs narration and music, and composes deterministically with Ruby and FFmpeg in pinned containers. Renders a draft first, then a final, and regenerates single scenes from cached content keys. Works from a PRD alone.
---

# CF walkthrough

Source: Stephanie Houde and Charles Hill, "What do Prototypes Prototype?" (1997), via cf:prototyping; Jakob Nielsen, ten usability heuristics (1994), via cf:usability; the ElevenLabs docs index https://elevenlabs.io/docs/llms.txt.

Load cf:prototyping, cf:usability, and cf:fractal by name before writing anything, and cf:narrate and cf:music by name before the estimate and render steps. Load cf:b-roll by name before authoring or rendering any `ai-broll` scene. Every scene cites the heuristic ids it shows in `heuristics_shown`, using the H1 to H10 labels from cf:usability. This skill carries no heuristic checklist of its own.

## Inputs

A PRD, SOW, or brief is enough. Optional: an existing `DESIGN.md` and `tokens.css`, existing screens, a brand mark, and a conventions note.

1. No `DESIGN.md` at the repo root: run the cf:design flow first (critics, grill, wholesale write, `design_tokens.rb lint` clean).
2. No screens under `walkthrough/<slug>/screens/`: run the cf:prototype flow (tokens only, local assets only, mock store seeded from `data/seed.json`, stills reviewed).
3. Then continue here. Each skill is also usable alone; this one only composes them.

## Voice: working backwards (core tenet)

The walkthrough is the launch video of the finished product, the press release seen on screen.

- Narration is present tense, as a shipped product: "Shelfwise records a loan in seconds", never "will", "could", "imagine", or "this concept".
- No concept badge, no disclaimer cards, no "prototype" or "mockup" wording in narration, captions, or frames.
- The truth trail lives only in the sidecar (below) and in the storyboard's `requirements` and `assumptions` fields. Nothing about provenance appears in the video.

## Steps

1. Pick a slug (`[a-z0-9][a-z0-9-]*`). Everything lands in `walkthrough/<slug>/`; `.cache/`, `flats/`, `*.mp4`, and `overview*.png` are ignored by the slug dir ignore file.
2. Write `storyboard.json` (schema in `reference/storyboard-schema.md`): one scene per user goal, ordered as the story, each with a screen, scripted interactions, narration text, at least one requirement anchor or assumption, hypotheses from cf:prototyping, and `heuristics_shown`. A scene that shows a result of an earlier action names `store.from_scene`. Never author `duration_ms`; it is derived from measured narration.
3. Declare the review in storyboard.json: `"review": { "kind": "explainer|promo|demo", "audience": "...", "purpose": ["outcome a viewer can state afterward"] }`. The draft roast reads it and refuses to run without an audience and a purpose. When `kind` is absent, `roast.rb infer --storyboard <file>` previews the inferred one; exit 3 means ambiguous, so ask the user with AskUserQuestion (candidates as options, and any missing audience or purpose the same way) and write the answer into `review`; under away mode take the top candidate and report the assumption; `validate` warns when it is absent. Validate and pin keys: `ruby ~/.claude/cf/bin/walkthrough_storyboard.rb validate walkthrough/<slug>/storyboard.json --fix`.
4. Render the readable copy: `walkthrough_storyboard.rb render-md walkthrough/<slug>/storyboard.json`. storyboard.md is generated and never hand-edited.
5. Write the sidecar: `ruby ~/.claude/cf/bin/walkthrough_assumptions.rb walkthrough/<slug>/storyboard.json` writes `ASSUMPTIONS.md` (invented features, fictional data including every seed collection, each Simple Icons logo with its guidelines link and license field, unsupported claims, and the Houde and Hill role plus look-and-feel statement) and `THIRD_PARTY_NOTICES`.
   Optional B-roll: a scene may be `kind: "ai-broll"`, a short AI clip animated from an existing still (for example the hero still made with cf:image), never for UI. It carries a `broll` block and no screen; the rubric, ceiling, and fallbacks are in cf:b-roll. Every clip is listed under "Generated footage" in `ASSUMPTIONS.md`.
6. Estimate: `ruby ~/.claude/cf/bin/walkthrough_render.rb walkthrough/<slug> --estimate-only` prints the ElevenLabs, OpenAI (including the roast loop's rounds), and Google (b-roll) cost of everything not yet cached, with the b-roll ceiling (`--max-usd <n>`, default 1.00); `elevenlabs.rb narrate --storyboard <json> --estimate-only` and `elevenlabs.rb music --storyboard <json> --estimate-only` (cf:narrate, cf:music) price each part alone. Show it to the user before any paid call.
7. Draft: `walkthrough_render.rb walkthrough/<slug> --draft` (medium image quality). It narrates (the cf:narrate flow over the same cache), generates images, generates b-roll clips (cf:b-roll; a failed or over-ceiling clip falls back to Ken Burns or the static still and the render continues), captures frames in the pinned browserless container, composes music for the total timeline (the cf:music flow), rebuilds `manifest.json`, and assembles with two FFmpeg passes. Every draft then runs the two gates below and prints both results, and the roast loop runs on it before any human review. Review the stills, the captions, and the draft MP4 with the user, scene by scene, against cf:usability, only once the loop has stopped. The roast loop's settings come from `change_config.design.roast` in the repo's root `CHANGE.md` when no flag is given: `target` (default 8.5), `rounds` (default 4), `max_usd` (the run total, default 2.00), `model` (default the cf:roast critic), and `auto` (default true; `auto: false` is the same as `--no-roast`). `--roast-max-usd`, `--no-roast`, and `--allow-roast-findings` keep working and win over the config. The render reads `CHANGE.md` from the working directory, so run it from the repo root. No signoff step is added: the loop still runs straight through.
8. Final: `walkthrough_render.rb walkthrough/<slug> --final` (high image quality). It refuses while the UX lint has any finding, or the roast loop has not finished or has an open P0 or P1 (see Gates). It prints the manifest hash and the MP4 sha256; the MP4 is under `.cache/render/<manifest_hash>/`.
9. Flats (required output alongside the MP4): author `flats.json` from the PRD information architecture (every major screen plus empty, error, and success states, not only the screens in the video), then `ruby ~/.claude/cf/bin/prototype_flats.rb walkthrough/<slug>`. See the cf:prototype Flats section; it writes `flats/{light,dark}/`, the two overview boards, and `flats/index.md`. Only when the user asks (or `--push-figma`), push the flats to Figma per the cf:prototype "Push to Figma (only when asked)" section.
10. Publish (only when the user asked for it or approves the final; never auto-fire, since it uploads to GitHub): `ruby ~/.claude/cf/bin/walkthrough_publish.rb walkthrough/<slug> [--pr N | --issue N | --none] [--comment]` (or pass the MP4 path). See Publishing below.

## Built apps (live scenes)

The same pipeline demos an app that already runs. A scene whose `screen` is `{ "url": "https://app.localhost/..." }` instead of `{ "html": ... }` is a live scene; a board may mix both. Fields are in `reference/storyboard-schema.md`.

- Sessions: a live scene starts logged out with a fresh, empty session unless it names a `persona` (a top-level login recipe run once per render and reused by every scene with that persona) or `session_from_scene` (an earlier live scene's end cookies and storage). Login is never required; a scene may film the login itself with `type` ops, a password typed from `env`.
- Credentials come only from env var names. Env-typed values reach the page alone: logs, captions, cache keys, the lint and roast reports, and errors carry `[masked]`, and the password field shows its normal dots. Sessions stay in memory and are never written.
- Browser: top-level `browser.network`, `browser.add_hosts`, and `browser.ignore_https_errors` reach the pinned browserless container and the page. Live capture never runs on `--network none`; prototype capture stays offline.
- Waits are per scene (`wait.until` of `domcontentloaded` or `load`, a `selector`, `settle_ms`), never networkidle, which hangs under dev servers with HMR sockets. `storage` clears and seeds session and local storage before navigation, so once-per-session UI shows on cue.
- Time: the controlled clock cannot reach a real app, so a live scene records in real time. A CDP screencast runs while the scripted steps play, and each tick at the board fps samples the latest frame; the cursor is composited from `cursor.json` as usual. One scene must fit one browserless call (about 115 s with its login).
- Cache: no screen sha, mock store, seed.json, or inline assets. A live scene is keyed by URL, persona, session parent, steps, waits, storage, viewport, fps, and duration, and recaptures only with `--recapture` or `--scene <id>` (which also recaptures the scenes that take their session from it). A cached session parent is replayed without frames, so its actions run again against the app.
- Devices: `devices` (`desktop`, `phone`, or both) and `layout` (`single` or `side_by_side`) film a scene on a phone under mobile emulation, composited in a plain bezel above the caption band with tap ripples, or both devices at once against the same session.
- Compose: a live scene's `mailto:`, `sms:`, and `tel:` clicks are caught and parsed, not followed. A `kind: "compose"` scene fills a neutral mail or text composer from that link (`compose.from_scene`) or an explicit spec, then types and sends. Compose scenes are simulated UI for walkthroughs and never send anything.
- Message: a `kind: "message"` scene shows a simulated inbound sms (lock screen banner or thread) or email (inbox row or open message with a call to action into the next scene), styled from the project tokens. On a prototype board `walkthrough_message.rb` renders it into a screen file, optionally inside a project shell. Nothing is sent or received.
- Gates: the UX lint runs in the live page during capture and the draft roast reads the MP4, so both still gate `--final`. Flats are prototype-only.

## Gates

Two gates stand between a draft and `--final`.

1. UX lint (free, always on, draft and final). Every capture runs `PrototypeUxLint` in the page at scene start, middle, and end, at each scripted step, half a second after each click, and when a toast or sheet first appears. Rules: `empty-control`, `occlusion`, `clipped-text`, `caption-safe`, `cursor-over-label`, `contradictory-state` (defined in cf:prototype), plus `device-frame` across scenes: every scene's device frame keeps the first scene's layout size and aspect ratio and its rendered size. Only a scene declaring `"camera": { "zoom": <0.5..3> }` may render it larger or smaller, uniformly and at most by that factor, which its screen implements as a smooth scale of the whole frame. Keep the device and every control clear of the caption band in both caption modes; pick one device size for the whole video. Each scene's report sits in its frames dir; the merged report is `ux-lint.json` beside the MP4. Any finding blocks `--final`; `--allow-ux-findings` overrides. It only reads layout, so clean screens keep their frame keys and frames.
2. Draft roast loop (paid, on by default). No human sees a final until the roast loop has finished on the draft. After assembly the render pulls keyframes from the draft MP4 (each scene's start, middle, and end, plus each toast or sheet's first frame), builds a transcript (each scene's narration with its time span and words per minute, plus the rendered caption cues), prints the estimate, and runs one cf:roast round. The critic reads the frames and the transcript together against `WalkthroughRoast::RUBRIC`: the visual checks (blank or unlabeled controls, overlays hiding controls, cursor and label collisions, state contradictions, caption and safe-area collisions including the bottom caption band, device frames that change shape or size, clipped content, readability at 1080p, cf:fractal and cf:usability consistency) and the narration checks (pacing, clarity and jargon, narration that does not match what is on screen, caption-band clash). Rounds land in `walkthrough/<slug>/roast/` (`round-N.json`, `round-N.md`, `round-N.response.json`, `spend.json`, keyframes under `keyframes/round-N/`). `--no-roast` skips it for an offline draft.

The loop (this session drives it, the script gates and reports):

- Each draft round prints `roast loop: continue|stop: <reason>`. On `continue`: write `round-N.response.json` (accept or rebut every issue, per cf:roast), apply the accepted fixes to the storyboard, screens, or narration, run `validate --fix`, and render the next draft. Only scenes whose keys changed re-render (cached frames, audio, and images are reused), so a fix costs one scene, not the video. The next draft runs the next roast round automatically.
- Stop rule: score at or above 8.5 with no open P0 or P1 (converged), or 4 rounds, or the run spend cap. A cap stop is not a pass: the draft reports what is still open, and `--final` still refuses while a P0 or P1 stands.
- Spend: every round prints its estimate first (`roast estimate:`, with the run cap and what is left) and its cost is logged in `roast/spend.json`. `--roast-max-usd <n>`, else `max_usd` in `change_config.design.roast`, is the cap for the whole run across rounds, default $2.00 (`WalkthroughRoast::DEFAULT_CEILING_USD`). A round whose estimate passes what is left is skipped, the loop ends, and the open findings are reported; the cap is never raised silently. A missing key skips the round and the draft stands; `--final` then refuses for want of a roast on record.
- Contested calls (a rebuttal the critic keeps repeating, a fix that conflicts with DESIGN.md) go to the user with AskUserQuestion, as in cf:roast.

`--final` refuses with no roast on record, with an open P0 or P1 not rebutted in its response file, or while the loop is neither converged nor capped. `--allow-roast-findings` overrides all three; `--no-roast` on the final run waives only the no-roast-on-record case. Offer `--final` to a human only after the loop prints `stop`.

## Publishing

Context rule: attach the final MP4 to whatever artifact the request is about, a pull request, an issue, or nothing. Target selection, in order: an explicit `--pr N`, `--issue N`, or `--none`; else the open PR of the current branch; else no target, no upload, and the file stays on disk (the path is printed).

- Upload reuses `ChangeScreenshotUpload` (the same user-attachments endpoint, `gh auth token` auth, and never-raise degradation as cf:screenshot, see `skills/screenshot/SKILL.md`), sent as `video/mp4`. An orphaned attachment from a failed run is an accepted risk there too.
- GitHub rejects attachments over `WalkthroughPublish::MAX_BYTES` (10 MB). A larger MP4 gets a smaller `walkthrough.pr.mp4` sibling transcoded in the pinned `ChangeDocker::FFMPEG_IMAGE` container (CRF ladder, last rung also scales down); the original is kept. If no rung fits, nothing uploads and the original stays on disk.
- The two flats overview boards (`flats/light/overview.png`, `flats/dark/overview.png`) upload through the same uploader as PNGs and are attached as images under the video in the same section; a board that fails to upload is skipped. The individual flats stay on disk.
- The returned `https://github.com/user-attachments/assets/<uuid>` url goes on its own line, which GitHub renders as an inline player, inside a `<!-- cf:walkthrough:start -->` ... `<!-- cf:walkthrough:end -->` `## Walkthrough` section. Re-running replaces that section instead of appending another. `--comment` posts it as a comment instead of editing the PR or issue body.
- Any failure (no token, non-201, `gh` error) degrades to leaving the file on disk and reporting why. A PR body edit is comment-class and is not gated by merge mode.

## Per-scene regeneration

Edit the one scene in `storyboard.json`, then:

```
ruby ~/.claude/cf/bin/walkthrough_storyboard.rb validate walkthrough/<slug>/storyboard.json --fix
ruby ~/.claude/cf/bin/walkthrough_render.rb walkthrough/<slug> --scene <id>
```

Only that scene's stale keys regenerate (frames, audio, or images); everything else is read from the cache and the video reassembles. `walkthrough_storyboard.rb stale <json>` lists what would regenerate. A changed narration shifts later scene offsets and, when the total length changes, the music key; a changed `from_scene` dependency recaptures its dependents. Restyling or retiming the cursor needs no recapture: FFmpeg composites it from `cursor.json`.

## Keys and licensing

- Keys come from the environment or the secrets env file named by `CF_SECRETS_ENV` (no default path; unset means the process environment only): `ELEVEN_LABS_API_KEY` (fallback `ELEVENLABS_API_KEY`) `OPENAI_API_KEY`, and `GEMINI_API_KEY` (b-roll only; a missing one degrades b-roll scenes to their fallback). A missing key fails with a named error only when that provider is needed; a fully cached run needs no keys. Never print or write a key.
- Optional key-setup note: `npx @elevenlabs/cli onboard init` exists for minting an ElevenLabs key. This skill does not use it and never runs it; the render calls the REST API directly.
- ElevenLabs music for commercial use needs the Starter plan or above; film or broadcast use needs Enterprise. Check the current terms before publishing.

## Determinism

Same manifest hash and same image digests mean the same timeline, the same frame keys, and the same FFmpeg argv. A byte-identical MP4 is advisory, not guaranteed. Audio is normalized to -16 LUFS in two loudnorm passes; captions are soft only by default (a `mov_text` track in the MP4 plus a `walkthrough.vtt` sidecar beside it), and `--burn-captions` opts in to burning them into the frames. The manual release check is `reference/release-check.md`.

## Layout

```
walkthrough/<slug>/
  storyboard.json  storyboard.md  manifest.json  ASSUMPTIONS.md  THIRD_PARTY_NOTICES
  screens/<scene-id>.html  screens/tokens.css  screens/mock-store.js  screens/assets/
  data/seed.json  flats.json  .gitignore (.cache/ flats/ *.mp4 overview*.png)
  flats/  index.md  light/  dark/  (generated, ignored)
  roast/  round-N.json  round-N.md  round-N.response.json  keyframes/
  .cache/  frames/  audio/  music/  images/  broll/  icons/  render/<manifest_hash>/
```

## Done when

- `validate` is clean with no stale keys, and storyboard.md is regenerated.
- Every scene has a requirement or assumption, cites `heuristics_shown`, and its narration is present tense with no concept framing.
- `flats/` is rendered for every IA screen and key state in both themes, with `index.md` and both overview boards.
- `ASSUMPTIONS.md` and `THIRD_PARTY_NOTICES` are current.
- The user reviewed the draft, and the final MP4 path, manifest hash, and MP4 sha256 are reported, and the MP4 is published to the request's PR or issue when there is one.
