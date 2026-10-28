# storyboard.json (schema_version 1)

`walkthrough/<slug>/storyboard.json` is the source of truth. `storyboard.md` is rendered from it and never hand-edited. Validated by `walkthrough_storyboard.rb validate`.

## Top level

```json
{
  "schema_version": 1,
  "slug": "shelfwise",
  "title": "string",
  "source_docs": [{ "path": "docs/prd.md", "sha256": "hex" }],
  "design_md_sha256": "hex",
  "tokens_css_sha256": "hex",
  "viewport": { "w": 1920, "h": 1080, "dpr": 1 },
  "fps": 30,
  "voice": { "provider": "elevenlabs", "voice_id": "string", "model": "eleven_multilingual_v2", "output_format": "mp3_44100_128" },
  "music": { "provider": "elevenlabs", "model": "music_v1", "prompt": "string", "composition_plan": null, "gain_db": -18 },
  "cursor": { "sprite": "default", "scale": 1.0 },
  "hypotheses": [{ "id": "H-01", "text": "string", "dimension": "role|look_and_feel" }],
  "scenes": []
}
```

`music` may be `null` for a narration-only walkthrough.

## Per scene

```json
{
  "id": "lend-book",
  "title": "string",
  "order": 1,
  "user_goal": "string",
  "action": "string",
  "screen": { "html": "screens/lend-book.html", "state": "default" },
  "store": { "seed": "data/seed.json", "from_scene": "earlier-scene", "patch": [{ "op": "set", "path": "loans.0.due", "value": "2026-11-11" }], "prng_seed": 42 },
  "interactions": [
    { "t_ms": 0, "op": "move", "target": "#borrower", "duration_ms": 600, "easing": "easeInOutCubic" },
    { "t_ms": 700, "op": "click", "target": "#borrower" },
    { "t_ms": 900, "op": "type", "target": "#borrower", "text": "Avery Quill", "cps": 12 },
    { "t_ms": 2400, "op": "hover", "target": ".row:last-of-type" },
    { "t_ms": 3000, "op": "wait", "duration_ms": 500 }
  ],
  "narration": { "text": "string", "measured_ms": 0 },
  "requirements": [{ "source": "docs/prd.md", "anchor": "#lending" }],
  "assumptions": [{ "id": "A-01", "text": "string" }],
  "hypotheses": ["H-01"],
  "heuristics_shown": ["H1", "H6"],
  "emphasis": "string",
  "hero_still": false,
  "images": [{ "prompt": "string", "size": "1024x1024", "quality": "medium", "refs": [] }],
  "timing": { "min_ms": 3000, "pad_ms": 400, "transition": { "type": "cut", "ms": 0 }, "music_duck_db": -12 },
  "deps": { "frames_key": "hex", "audio_key": "hex", "asset_keys": ["hex"] }
}
```

## Rules

- `id` matches `\A[a-z0-9][a-z0-9-]*\z` and is unique; `order` is unique and contiguous from 1.
- `transition.type` is `cut` or `fade`; a fade's `ms` is in 100..1500 and overlaps the previous scene.
- `op` is one of move, click, type, hover, wait; `t_ms` is a non-negative integer and non-decreasing; `target` is required except for wait.
- Duration is derived, never authored: `duration_ms = max(min_ms, measured_ms + pad_ms)`. A `duration_ms` key on a scene or in `timing` is a validation error. `measured_ms` is written by the renderer from the narration alignment.
- Every scene `hypotheses` id resolves to the top-level list; every scene has at least one requirement or one assumption.
- `store` is optional. `seed` must exist under `data/`. `from_scene` names an earlier scene (lower `order`), so there are no cycles. The starting state is the seed, then the `from_scene` end state, then the `patch` ops (`set`, `push`, `delete`). `prng_seed` is an integer, derived from the scene id when absent.
- `deps` keys are recomputed and compared. A stale key is reported, not silently fixed; `--fix` rewrites them. A `frames_key` of `null` means a `from_scene` dependency has not been captured yet.
- Narration is present tense, as a shipped product, with no concept framing. Provenance goes in `requirements` and `assumptions`, never in narration.

## Keys

All keys are sha256 hex over canonical JSON (sorted keys, no whitespace).

- `frames_key`: screen html sha256, the inlined screen with every local asset, `tokens_css_sha256`, interactions, viewport, fps, the browserless image digest, the capture script version, the derived duration, the seed sha256, the mock-store.js sha256, the resolved starting state, and `prng_seed`.
- `audio_key`: narration text, voice id, model, output format, and voice settings.
- `asset_key` (images): prompt, model id, size, quality, and reference image digests.
- `music_key`: the music block and the total timeline duration.
- `manifest_hash`: sha256 of manifest.json in canonical form, excluding the hash itself.
