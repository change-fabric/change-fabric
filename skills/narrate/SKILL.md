---
name: cf:narrate
group: workflow
description: Narration command. Turns text, a script file, or a storyboard.json (all scenes or one with --scene) into ElevenLabs narration audio, a character alignment JSON, and an SRT, cached by content key, with a cost estimate printed before any paid call. Voice, model, and output format are overridable. Usable alone, outside any walkthrough, and loaded by name by cf:walkthrough.
---

# CF narrate

Source: the ElevenLabs docs index https://elevenlabs.io/docs/llms.txt (text to speech with timestamps).

A thin command over `ruby ~/.claude/cf/bin/elevenlabs.rb narrate`, the shared ElevenLabs library and CLI. It has no provider code of its own.

## Inputs

Exactly one source:

- `--text "<words>"`: one inline passage.
- `--file <script.txt>`: a script file, read whole and stripped.
- `--storyboard <storyboard.json>`: every scene with narration text, in `order`; `--scene <id>` narrates just that scene. The voice, model, output format, and settings come from the board's `voice` block.

Overrides: `--voice <voice_id>` (required unless the storyboard carries one), `--model <model_id>` (default `eleven_multilingual_v2`), `--format <output_format>` (default `mp3_44100_128`), `--cache <dir>` (default `.cache`).

## Steps

1. Estimate first: add `--estimate-only`. It prints `ElevenLabs estimate: narration $X, ...` for the text not already cached and makes no call. Show it to the user before the paid run.
2. Run without `--estimate-only`. Each item prints `audio:`, `alignment:`, and `srt:` paths under `<cache>/audio/<audio_key>.*`. A storyboard run prefixes each with `scene <id>:`.
3. The `audio_key` is a hash of text, voice, model, output format, and settings. A repeat run is a cache hit: no HTTP call and no key needed. A storyboard run shares the walkthrough render's cache, so audio narrated here is reused by `walkthrough_render.rb`.
4. Narration in a walkthrough is present tense, as a shipped product; cf:walkthrough owns that voice rule.

## Keys

`ELEVEN_LABS_API_KEY` (fallback `ELEVENLABS_API_KEY`) from the environment or the env file named by `CF_SECRETS_ENV`. A missing key fails with a named error only when a call is actually needed. Never print or write a key; the library scrubs it from every error.

## Done when

- The estimate was shown before any paid call.
- The audio, alignment, and SRT paths are reported, and a failed call is reported with its HTTP status and no key.
