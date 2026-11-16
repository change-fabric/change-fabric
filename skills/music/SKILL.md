---
name: cf:music
group: workflow
providers: [elevenlabs]
description: Music command. Turns a prompt plus duration, a composition plan file, or a storyboard.json (sized to its timeline) into an ElevenLabs music track cached by content key, with a cost estimate printed before any paid call. Composition plans are unseedable, so the cache is authoritative. Paid, so it runs only when invoked by name or loaded by cf:walkthrough, never auto-applied or chosen on a model guess. Usable alone, outside any walkthrough.
---

# CF music

Source: the ElevenLabs docs index https://elevenlabs.io/docs/llms.txt (music compose).

A thin command over `ruby ~/.claude/cf/bin/elevenlabs.rb music`, the shared ElevenLabs library and CLI. It has no provider code of its own.

## Inputs

Exactly one source:

- `--prompt "<style>" --duration-ms <ms>`: a prompt with a length. A prompt without `--duration-ms` is an error.
- `--plan <plan.json>`: a composition plan. Each section's `duration_ms` must be 3000 to 120000, and the plan must not carry a `seed`; the track length is the sum of the sections.
- `--storyboard <storyboard.json>`: the board's `music` block (prompt or composition plan, model) sized to the derived timeline length.

Overrides: `--model <model_id>` (default `music_v1`), `--cache <dir>` (default `.cache`). Lengths clamp to 3000 to 600000 ms.

## Steps

1. Estimate first: add `--estimate-only`. It prints the music cost for a track not already cached and makes no call. Show it to the user before the paid run.
2. Run without `--estimate-only`. It prints `music: <cache>/music/<music_key>.mp3`.
3. The `music_key` hashes the prompt or plan, model, and length. A plan cannot be seeded, so the same plan can sound different on a regenerate; the cached file is the authority. Keep the one you chose, and delete its cache entry only to deliberately re-roll. A repeat run is a cache hit: no call, no key. A prompt request also asks for no outro, fade, or ending (the walkthrough renderer fades the bed itself); that wording sits outside the key, so beds cached before it stay valid.
4. A storyboard run shares the walkthrough render's cache, so a track composed here is reused by `walkthrough_render.rb`.

## Keys and licensing

`ELEVEN_LABS_API_KEY` (fallback `ELEVENLABS_API_KEY`) from this project's enrolled key only (env vars are ignored); never print or write it. Exit 4 with a `cf_enroll` line means this project has no usable key: paste the enrollment snippet (or confirm an ancestor key, or stage it with cf:secret-intake and push it `--to cf-key:<provider>`) and re-run, see `skills/walkthrough/reference/key-enrollment.md`. A provider rejection is named, never generic: exit 4 with `"reason":"revoked"` (enroll a new key), or exit 1 with a `cf_key_error` line naming `quota_exhausted` (never retried), `rate_limited` (after 3 attempts), `bad_request` (with the provider message) or `server`, plus the next step to relay; see Provider failures in that file. Music for commercial use needs the ElevenLabs Starter plan or above, and film or broadcast use needs Enterprise. Check the current terms before publishing.

## Done when

- The estimate was shown before any paid call.
- The track path is reported, and a failed call is reported with its HTTP status and no key.
