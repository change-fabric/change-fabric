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
  "deps": { "frames_key": "hex", "audio_key": "hex", "asset_keys": ["hex"], "broll_key": "hex (ai-broll scenes only)" }
}
```

## ai-broll scene

A scene with `"kind": "ai-broll"` (default `screen`) is a short AI clip animated from an existing still, never UI. It has no `screen`, `interactions`, or `store`; narration, `timing`, `requirements` or `assumptions`, and transitions work as for any scene.

```json
{
  "id": "the-shed", "order": 4, "kind": "ai-broll",
  "broll": { "source_image": "screens/assets/shed.png", "prompt": "slow push in, soft light", "seconds": 4,
             "model": "gemini-omni-1.1-flash", "fallback": "kenburns" },
  "narration": { "text": "string" }, "assumptions": [{ "id": "A-09", "text": "string" }],
  "timing": { "min_ms": 3000, "pad_ms": 400, "transition": { "type": "fade", "ms": 400 } }
}
```

- `source_image` is a png, jpg, or webp inside the walkthrough directory (no `..`, no absolute path) and must exist. `prompt` is required. `seconds` is an integer 1 to 10, a length hint; the scene's derived duration still decides how long it plays (the clip is trimmed, or its last frame held).
- `model` defaults to `gemini-omni-1.1-flash` (`CF_BROLL_MODEL` overrides); retired ids (Veo, `gemini-omni-flash-preview`) fail validation.
- `fallback` is `kenburns` (default) or `static`, used when generation fails, is over the cost ceiling, or has no key. It never blocks a render.
- The render normalizes the clip (scaled and padded to the viewport, the board `fps`, no audio) into PNG frames in the pinned FFmpeg container, so it enters the timeline exactly like captured frames.
- `render-md` shows the source, seconds, model, fallback, and prompt. `ASSUMPTIONS.md` lists every clip under "Generated footage".

## Live scene (a built app)

A scene whose `screen` is `{ "url": "https://..." }` films a running app. `screen` takes exactly one of `html` or `url`. A live scene carries no `store` or `images`.

Top-level additions, both optional:

```json
{
  "browser": { "network": "app-net", "add_hosts": ["app.localhost:172.17.0.1"], "ignore_https_errors": true },
  "personas": {
    "member": {
      "login": {
        "url": "https://app.localhost/login",
        "steps": [
          { "type": "fill", "selector": "#email", "env": "DEMO_MEMBER_EMAIL" },
          { "type": "fill", "selector": "#password", "env": "DEMO_MEMBER_PASSWORD" },
          { "type": "click", "selector": "button[type=submit]" },
          { "type": "wait", "selector": "#dashboard" }
        ],
        "success_selector": "#dashboard"
      }
    }
  }
}
```

A live scene:

```json
{
  "id": "inbox", "order": 3, "title": "Inbox",
  "screen": { "url": "https://app.localhost/inbox" },
  "persona": "member",
  "wait": { "until": "domcontentloaded", "selector": "main [data-loaded]", "settle_ms": 300 },
  "storage": { "clear": ["sessionStorage"], "set": { "localStorage": { "tour": "on" } } },
  "interactions": [
    { "t_ms": 0, "op": "scroll", "target": "#inbox" },
    { "t_ms": 400, "op": "move", "target": "#inbox .row:first-child", "duration_ms": 600 },
    { "t_ms": 1100, "op": "click", "target": "#inbox .row:first-child" }
  ],
  "narration": { "text": "string" }, "assumptions": [{ "id": "A-03", "text": "string" }],
  "timing": { "min_ms": 3000, "pad_ms": 400 }
}
```

A filmed login, with later scenes reusing its session:

```json
{ "id": "sign-in", "order": 1, "screen": { "url": "https://app.localhost/login" }, "persona": null,
  "interactions": [
    { "t_ms": 0, "op": "type", "target": "#email", "text": "member@example.test" },
    { "t_ms": 1200, "op": "type", "target": "#password", "env": "DEMO_MEMBER_PASSWORD" },
    { "t_ms": 2400, "op": "click", "target": "button[type=submit]" }
  ] }
{ "id": "dashboard", "order": 2, "screen": { "url": "https://app.localhost/" }, "session_from_scene": "sign-in" }
```

- `browser.network` is a docker network name the browser container joins (never `none`); `add_hosts` entries are `"host:ip"` and become `--add-host`; `ignore_https_errors` (bool) accepts a dev server's self-signed certificate.
- `personas.<name>.login`: `url` (http or https), a non-empty `steps` list, and `success_selector`, waited for after the steps. A step is `fill` (`selector`, `env`), `click` (`selector`), or `wait` (`selector`). A `fill` takes its value only from `env`, an env var name like `DEMO_MEMBER_PASSWORD`; a `value`, `password`, `secret`, `token`, or `text` key is a literal credential and fails validation.
- `persona` (optional, may be `null`) names a top-level persona: that login runs once per render and its cookies and storage seed every scene naming it; different personas get separate sessions. `session_from_scene` (optional) names an earlier live scene whose end session this scene starts from, like `store.from_scene`. The two are exclusive. With neither, the scene starts logged out with an empty session. Nothing requires a login.
- `wait` (optional): `until` is `domcontentloaded` or `load` (default `load`; networkidle is refused, it hangs under dev servers with HMR sockets), `selector` is waited for after it, then `settle_ms` (non-negative integer) passes before the first frame.
- `storage` (optional): `clear` lists `sessionStorage`, `localStorage`, or a single key (removed from both); `set` maps `sessionStorage` or `localStorage` to key-value pairs (non-string values are JSON encoded). It applies after the session is restored and before the page loads, and only to the first load of the scene.
- Live `interactions` add `scroll` (`target`, scrolled into view) to move, click, type, hover, and wait. A `type` op takes exactly one of `text` or `env`. `scroll` and `env` typing need a live scene.
- Env-typed and filled values are masked as `[masked]` in logs, errors, and the lint report, and are not key material. An unset env var fails with its name only.
- Live scenes record in real time (no controlled clock): a screencast is sampled at the board `fps`. Flats are prototype-only; `prototype_capture.rb` skips live scenes.

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

- `frames_key` (live scene): URL, the persona name and login spec (env names, never values), the session parent's frames key, interactions, `wait`, `storage`, viewport, fps, the derived duration, `browser`, the browserless image digest, and the live capture version. It recaptures only with `--recapture` or `--scene` (which pulls in its `session_from_scene` dependents).
- `frames_key`: screen html sha256, the inlined screen with every local asset, `tokens_css_sha256`, interactions, viewport, fps, the browserless image digest, the capture script version, the derived duration, the seed sha256, the mock-store.js sha256, the resolved starting state, and `prng_seed`.
- `audio_key`: narration text, voice id, model, output format, and voice settings.
- `asset_key` (images): prompt, model id, size, quality, and reference image digests.
- `broll_key` (ai-broll): source image digest, prompt, seconds, model id, resolution, and aspect ratio. An ai-broll scene's `frames_key` hashes the clip key (or, for a fallback, the source image digest and mode), the viewport, fps, frame count, and the FFmpeg image digest.
- `music_key`: the music block and the total timeline duration.
- `manifest_hash`: sha256 of manifest.json in canonical form, excluding the hash itself.
