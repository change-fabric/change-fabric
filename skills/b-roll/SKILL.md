---
name: cf:b-roll
group: workflow
description: B-roll command. Animates one local still (typically a gpt-image-2 hero) into a short silent clip with the Gemini Interactions API (gemini-omni-1.1-flash, image to video only), cached by content key, with a cost estimate and an explicit ceiling before any paid call and a deterministic Ken Burns or static fallback so a failed generation never blocks a render. Never for UI. Paid, so it runs only when invoked by name or loaded by cf:walkthrough, never auto-applied or chosen on a model guess. Usable alone, outside any walkthrough.
---

# CF b-roll

Source: the Gemini API video guide https://ai.google.dev/gemini-api/docs/omni, the pricing page https://ai.google.dev/gemini-api/docs/pricing, and the deprecations page https://ai.google.dev/gemini-api/docs/deprecations (checked 2026-10-28).

A thin command over `ruby ~/.claude/cf/bin/b_roll.rb`, one small adapter (`scripts/b_roll.rb`) with one provider. No multi-provider orchestration.

## Rubric (read before authoring a shot)

- Image to video only: animate a still we already own (the gpt-image-2 hero, a product shot). Never text to video.
- Never generative video for UI. Screens, text, numbers, forms, and anything the viewer is meant to read stay HTML/CSS captured frames.
- No people, faces, or logos in the source still: Google may refuse recognizable people, and a likeness is a provenance risk.
- Prompt for motion, not content: "slow push in, soft light, no text". The request already adds "no audio, no dialogue, no on-screen text".
- The model returns an AAC track anyway. It is always dropped (`-an`); ElevenLabs supplies narration and music.
- Every shot has a fallback. Authoring `fallback: "kenburns"` (default) or `"static"` is required thinking, not optional polish.

## Inputs

`ruby ~/.claude/cf/bin/b_roll.rb <image> "<motion prompt>" <cache-root> [--seconds N] [--max-usd X] [--model ID] [--estimate-only]`

- `<image>`: a local png, jpg, or webp.
- `--seconds` (default 4, whole seconds 1 to 10): a length hint written into the prompt. A live check returned exactly 4.0 s for a 4 s hint; other lengths are unverified, so the render holds the last frame or trims to the scene.
- `--max-usd` (default 1.00): the run's cost ceiling. A shot that would pass it is refused before the call.
- `--model` or `CF_BROLL_MODEL`: default `gemini-omni-1.1-flash`. Veo ids and `gemini-omni-flash-preview` are retired and refused (`RetiredModelError`); never hardcode a model id from memory, re-read the deprecations page.

## Steps

1. Estimate first: `--estimate-only` prints the cost (about $0.10 per output second at 720p) and makes no call. Show it to the user.
2. Run. It prints `<cache>/broll/<key>.mp4` and `spent about $X`. The `asset_key` hashes the source image digest, prompt, seconds, model, resolution, and aspect ratio, so a repeat run is a cache hit: no call, no key.
3. The request asks for URI delivery, so the job is a hosted file. The file id is written to `<cache>/broll/<key>.pending.json` before polling; a run interrupted or timed out after that resumes from the file with no second paid call. A `FAILED` file clears the pending record so the next run starts fresh.
4. The clip is validated with ffprobe (the pinned FFmpeg image, `--entrypoint ffprobe`): a video stream, real dimensions, at least 0.5 s. A clip that fails is not cached.

## Fallback chain

`generate_or_fallback` never raises. A named failure (`RequestError`, `PollTimeoutError`, `GenerationFailedError`, `ProbeError`, `CeilingError`, `RetiredModelError`) or a missing `GEMINI_API_KEY` degrades to the scene's fallback: Ken Burns (a slow zoom over the source still, the same push-in as `hero_still`), then the static still. The result is normalized to PNG frames in the pinned FFmpeg container, so the timeline, transitions, and narration are identical in all three modes. The frames key includes the mode, so a later successful generation is a clean regenerate, and a failed one is retried on the next render (each retry is charged against the ceiling up front, so raise `--max-usd` deliberately).

## Keys and licensing

- `GEMINI_API_KEY` from the environment or the secrets env file named by `CF_SECRETS_ENV`; only fetched when a paid call is actually made, never printed or written. Use a key restricted to the Gemini API.
- Every clip carries an invisible SynthID watermark; keep it intact. Record each clip in the walkthrough's `ASSUMPTIONS.md` under "Generated footage" (done automatically from the storyboard).
- Google does not claim ownership of generated content and the Services are for business purposes; on the paid tier prompts are not used for training. Terms for generated video are not spelled out on the terms page, so check the current Gemini API terms before publishing.

## Done when

- The estimate was shown before any paid call and the spend was reported.
- The clip path (or the fallback mode and its reason) is reported, and a failed call is reported with its HTTP status and no key.
