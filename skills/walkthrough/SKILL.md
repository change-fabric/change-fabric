---
name: cf:walkthrough
group: workflow
description: Flagship walkthrough command. Turns a PRD, SOW, brief, or an existing app into a cinematic narrated MP4 walkthrough without building the app, composing cf:design for DESIGN.md, cf:prototype for HTML/CSS mock screens and recorded motion, and cf:prototyping plus cf:usability for method and rubric. Writes storyboard.json as the source of truth, narrates in present tense as a shipped product, keeps the truth trail in an ASSUMPTIONS.md sidecar, generates ElevenLabs narration and music, and composes deterministically with Ruby and FFmpeg in pinned containers. Renders a draft first, then a final, and regenerates single scenes from cached content keys. Works from a PRD alone.
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
3. Validate and pin keys: `ruby ~/.claude/cf/bin/walkthrough_storyboard.rb validate walkthrough/<slug>/storyboard.json --fix`.
4. Render the readable copy: `walkthrough_storyboard.rb render-md walkthrough/<slug>/storyboard.json`. storyboard.md is generated and never hand-edited.
5. Write the sidecar: `ruby ~/.claude/cf/bin/walkthrough_assumptions.rb walkthrough/<slug>/storyboard.json` writes `ASSUMPTIONS.md` (invented features, fictional data including every seed collection, each Simple Icons logo with its guidelines link and license field, unsupported claims, and the Houde and Hill role plus look-and-feel statement) and `THIRD_PARTY_NOTICES`.
   Optional B-roll: a scene may be `kind: "ai-broll"`, a short AI clip animated from an existing still (for example the hero still made with cf:image), never for UI. It carries a `broll` block and no screen; the rubric, ceiling, and fallbacks are in cf:b-roll. Every clip is listed under "Generated footage" in `ASSUMPTIONS.md`.
6. Estimate: `ruby ~/.claude/cf/bin/walkthrough_render.rb walkthrough/<slug> --estimate-only` prints the ElevenLabs, OpenAI, and Google (b-roll) cost of everything not yet cached, with the b-roll ceiling (`--max-usd <n>`, default 1.00); `elevenlabs.rb narrate --storyboard <json> --estimate-only` and `elevenlabs.rb music --storyboard <json> --estimate-only` (cf:narrate, cf:music) price each part alone. Show it to the user before any paid call.
7. Draft: `walkthrough_render.rb walkthrough/<slug> --draft` (medium image quality). It narrates (the cf:narrate flow over the same cache), generates images, generates b-roll clips (cf:b-roll; a failed or over-ceiling clip falls back to Ken Burns or the static still and the render continues), captures frames in the pinned browserless container, composes music for the total timeline (the cf:music flow), rebuilds `manifest.json`, and assembles with two FFmpeg passes. Review the stills, the captions, and the draft MP4 with the user, scene by scene, against cf:usability.
   Every draft then runs the two gates below and prints both results.
8. Final: `walkthrough_render.rb walkthrough/<slug> --final` (high image quality). It refuses while the UX lint has any finding or the latest draft roast has an open P0 or P1 (see Gates). It prints the manifest hash and the MP4 sha256; the MP4 is under `.cache/render/<manifest_hash>/`.
9. Flats (required output alongside the MP4): author `flats.json` from the PRD information architecture (every major screen plus empty, error, and success states, not only the screens in the video), then `ruby ~/.claude/cf/bin/prototype_flats.rb walkthrough/<slug>`. See the cf:prototype Flats section; it writes `flats/{light,dark}/`, the two overview boards, and `flats/index.md`.
10. Publish (only when the user asked for it or approves the final; never auto-fire, since it uploads to GitHub): `ruby ~/.claude/cf/bin/walkthrough_publish.rb walkthrough/<slug> [--pr N | --issue N | --none] [--comment]` (or pass the MP4 path). See Publishing below.

## Gates

Two gates stand between a draft and `--final`.

1. UX lint (free, always on, draft and final). Every capture runs `PrototypeUxLint` in the page at scene start, middle, and end, at each scripted step, half a second after each click, and when a toast or sheet first appears. Rules: `empty-control`, `occlusion`, `clipped-text`, `caption-safe`, `cursor-over-label`, `contradictory-state` (defined in cf:prototype), plus `device-frame` across scenes: every scene's device frame keeps the first scene's layout size and aspect ratio and its rendered size. Only a scene declaring `"camera": { "zoom": <0.5..3> }` may render it larger or smaller, uniformly and at most by that factor, which its screen implements as a smooth scale of the whole frame. Keep the device and every control clear of the caption band in both caption modes; pick one device size for the whole video. Each scene's report sits in its frames dir; the merged report is `ux-lint.json` beside the MP4. Any finding blocks `--final`; `--allow-ux-findings` overrides. It only reads layout, so clean screens keep their frame keys and frames.
2. Draft roast (paid, every draft). After assembly the render pulls keyframes from the draft MP4 (each scene's start, middle, and end, plus each toast or sheet's first frame), prints the estimate, and runs one cf:roast round against the walkthrough rubric in `WalkthroughRoast::RUBRIC` (blank or unlabeled controls, overlays hiding controls, cursor and label collisions, state contradictions, caption and safe-area collisions including the bottom caption band, device frames that change shape or size between scenes, content cut off by its container or the device edge, readability at 1080p, cf:fractal and cf:usability consistency). Its ceiling is its own: `--roast-max-usd <n>`, default 0.50; an estimate past it, or a missing key, skips the round and the draft stands. Rounds land in `walkthrough/<slug>/roast/` (`round-N.json`, `round-N.md`, keyframes under `keyframes/round-N/`). `--no-roast` skips it for an offline draft.

Between drafts, follow cf:roast: write `round-N.response.json`, apply the accepted fixes, render the next draft. `--final` refuses while the latest round has a P0 or P1 not rebutted in its response file; `--allow-roast-findings` overrides. The script only gates and reports; judgment stays here.

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
