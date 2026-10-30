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
  "review": { "kind": "explainer|promo|demo", "audience": "string", "purpose": ["outcome a viewer must be able to state afterward"] },
  "scenes": []
}
```

`review` declares what the walkthrough is for; cf:roast judges against it (a purpose test over each outcome) and refuses to run without a non-empty `audience` and `purpose`. `kind` is `explainer` (no call to action required unless a purpose asks), `promo` (keeps the what, who, next-step test), or `demo` (must show the thing running). `validate` checks the shape when present and only warns when `review` is absent. CLI `--kind`, `--audience`, `--purpose` on roast.rb override it, and it overrides `change_config.design.roast.kind` and `.audience`.

`voice.eq` is optional narration EQ applied to the narration bus before the music duck: `"warm"` or `{ "low_shelf_hz": 150, "low_shelf_db": 3, "cut_hz": 3500, "cut_db": -2.5 }` (each hz/db pair optional but all-or-nothing, 20-20000 Hz, +-24 dB); it changes the manifest hash and so re-assembles, never `audio_key`.

`music` may be `null` for a narration-only walkthrough.

`tokens_css_sha256` is computed, never hand-written. `validate --fix` writes the sha256 of the canonical `tokens.css` (found by walking up from the walkthrough directory to the repo root, trying the `change_config.design.tokens` path from CHANGE.md, default `design/tokens.css`, then a bare `tokens.css`; `--tokens PATH` overrides) before it rewrites the deps, so every `frames_key` that hashes it goes stale and recaptures when the tokens change. Plain `validate` fails on a missing or stale hash. With no canonical `tokens.css` found, the field is left alone and not checked.

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
- Live `interactions` use the same ops as a prototype scene. A `type` op takes exactly one of `text` or `env`. `env` typing needs a live scene.
- Env-typed and filled values are masked as `[masked]` in logs, errors, and the lint report, and are not key material. An unset env var fails with its name only.
- Live scenes record in real time (no controlled clock): a screencast is sampled at the board `fps`. Flats are prototype-only; `prototype_capture.rb` skips live scenes.

## Devices and layouts

A live or compose scene picks the devices it films and how they share the frame:

```json
{ "phone": { "w": 390, "h": 844, "dpr": 2, "ua": "optional mobile user agent" } }
{ "id": "checkout", "screen": { "url": "https://app.localhost/checkout" }, "persona": "member",
  "devices": ["desktop", "phone"], "layout": "side_by_side",
  "interactions": { "desktop": [{ "t_ms": 0, "op": "click", "target": "#pay" }],
                    "phone": [{ "t_ms": 0, "op": "click", "target": "#menu" }] } }
```

- `devices` is `["desktop"]`, `["phone"]`, or `["desktop", "phone"]`; `layout` is `single` (default) or `side_by_side`. Two devices need `side_by_side`, and `side_by_side` needs both. No `devices` means desktop single: the board viewport, full bleed, as before.
- Top-level `phone` (optional) sets the phone viewport: `w` and `h` (integers in 100..4000), `dpr` (1..4), and `ua`. The default is 390 x 844 at dpr 2 with a generic mobile user agent. A phone scene runs under mobile emulation (`isMobile`, `hasTouch`, the mobile user agent).
- A phone or side-by-side scene is composited onto the board canvas: each device sits in a plain bezel on a neutral background, scaled to fit above the caption band, so captions clear every frame. A phone shows tap ripples instead of the arrow; the desktop keeps the arrow.
- Side-by-side devices are captured in parallel against the same URL and the same starting session. `interactions` is one list both devices play, or `{ "desktop": [...], "phone": [...] }`. A scene's end session (for `session_from_scene`) is its first device's. Cookies and storage are keyed by origin, so a session crosses between desktop and phone scenes.
- The device-frame lint compares frames only within one group (device and layout, such as `phone side_by_side`).
- The unreleased single `device` field is gone: validation rejects it in favor of `devices` and the board `phone` spec.

## Compose scene

`"kind": "compose"` films a simulated compose UI (a neutral mail window or text message composer, from the templates in `reference/compose/`). It never sends anything. A live scene's clicks on `mailto:`, `sms:`, and `tel:` links (and `window.open` of one) are caught instead of followed, parsed (to, cc, bcc, subject, body; sms recipients and body, percent decoded, line breaks kept), and written to the scene's `links.json`. A compose scene fills from the last email or sms link an earlier live scene caught, or from an explicit spec:

```json
{ "id": "inquiry", "order": 4, "kind": "compose", "compose": { "from_scene": "listing" },
  "interactions": [{ "t_ms": 0, "op": "type", "target": "#body", "text": "Two seats, please" },
                   { "t_ms": 2000, "op": "click", "target": "#send" }] }
{ "id": "text", "order": 5, "kind": "compose", "devices": ["phone"],
  "compose": { "channel": "sms", "to": "+15550100", "body": "On my way" } }
```

- `compose` is `{ "from_scene": "<earlier live scene>" }` alone, or explicit `channel` (`email` or `sms`), `to` (required), and for email `cc`, `bcc`, `subject`; `body` for both. Recipients are a string or a list.
- Field ids are fixed: `#to`, `#cc`, `#bcc`, `#subject`, `#body`, `#send`, and `#status`. Clicking `#send` shows the sent state.
- Line-anchored typing: a `type` op with `"after_line": "Name:"` puts the caret at the end of the first line of its target that starts with that text, then types there, so a prefilled template line is filled in on camera: `{ "t_ms": 0, "op": "type", "target": "#body", "after_line": "Name:", "text": " Sam Lee" }`. A missing line fails the capture. `after_line` works in any live or compose scene.
- Devices: an email compose is a mail window on desktop and full screen on a phone; an sms compose is a phone composer, centered as a narrow window on desktop. `side_by_side` films both at once.
- A compose scene has no `screen`, `store`, `persona`, `session_from_scene`, or `storage`; it takes `wait`, `devices`, and `layout`, and gets the UX lint. ASSUMPTIONS.md lists it under Simulated UI.
- An app that sets `location.href` to a `mailto:` link directly is not caught; give it an explicit spec.

## Message scene

`"kind": "message"` shows a simulated inbound notification or message: something that arrives, where a compose scene is something sent. It is its own kind rather than a compose `direction`, because its views, fields, and timing (a banner tapped into the next scene) share nothing with a composer. Nothing is sent or received.

```json
{ "id": "ask", "order": 4, "kind": "message", "devices": ["phone"],
  "message": { "channel": "sms", "view": "lock_banner", "from": "Sam Lee", "body": "Is the 9am slot still open?",
               "time": "now", "clock": "8:15", "date": "Saturday, November 21", "app": { "name": "Demo App", "icon": "screens/icon.svg" } },
  "interactions": [{ "t_ms": 1800, "op": "click", "target": "#banner" }] }
{ "id": "confirm", "order": 7, "kind": "message",
  "message": { "channel": "email", "view": "open", "from": "Demo App", "to": "sam@example.test", "subject": "Your loan is confirmed",
               "body": "Pick up Saturday at 9.", "cta": { "label": "View loan", "to_scene": "loan" } },
  "interactions": [{ "t_ms": 3000, "op": "click", "target": "#cta" }] }
```

- `channel` and `view`: `sms` with `lock_banner` or `thread`; `email` with `inbox` or `open`. `from` and `body` are required, and `subject` for an email. Optional strings: `to`, `preview` (defaults to the first body line), `time` (a label such as `now` or `8:02`), and on `lock_banner` only `clock` and `date`.
- `app` is `{ name, icon }`, the brand mark on the banner and the mail sender. The name defaults to the board title; the icon is an svg, png, jpg, or webp path under the project and defaults to the name's initial. Colors and type come from the project's `tokens.css` (`--bg`, `--surface`, `--text`, `--muted`, `--border`, `--btn`, `--accent`, `--font-sans`, `--radius`), with neutral fallbacks.
- `inbox` takes `others`, a list of `{ from, subject, preview, time }` rows around the new message. `open` takes `cta` `{ label, to_scene }`; `to_scene` must be the next scene, so the tap and the screen it opens read as one motion. A `lock_banner` tap (`#banner`) plays an open animation; cut to the app scene right after it.
- Fixed ids: `#banner`, `#message`, `#cta`, `#reply`, and `#send`. A `thread` takes a typed reply into `#reply`; clicking `#send` adds it as a delivered bubble.
- Live board: with no `screen`, the scene is filmed in the live browser like a compose scene and takes `devices` and `layout`.
- Prototype board: give it `screen.html` (a generated file) and run `ruby scripts/walkthrough_message.rb storyboard.json` to write it from the templates and the project's tokens. `shell` names a project screen holding `<div data-cf-message></div>`; the view is rendered into that slot, so the scene keeps the project's own stage and device frame. Validation flags a generated file that no longer matches its scene.
- Both get the UX lint and roast rubric item 10. ASSUMPTIONS.md lists each one under Simulated UI as a simulated notification.

## Rules

- `id` matches `\A[a-z0-9][a-z0-9-]*\z` and is unique; `order` is unique and contiguous from 1.
- `transition.type` is `cut` or `fade`; a fade's `ms` is in 100..1500 and overlaps the previous scene.
- `op` is one of move, click, dblclick, type, key, hover, scroll, wait; `t_ms` is a non-negative integer and non-decreasing; `target` is required except for wait and key.
- `dblclick` double-clicks `target` (a real two-press mouse sequence), for opening a file or a list row.
- `key` presses `keys` on its frame through CDP key events under the virtual clock: one key (`"Enter"`, `"Escape"`, `"a"`) or a chord with modifiers first (`"Control+C"`, `"Control+Shift+Esc"`). Modifiers are Control, Shift, Alt, Meta; `Ctrl`, `Cmd`, `Option`, `Esc`, `Return`, `Del`, and `Space` are aliases. An optional `target` is focused first. An unknown key fails validation.
- `scroll` takes a `target`. With integer `dx` and/or `dy` it scrolls that element by those pixels, instantly, so the same delta gives the same frame; with neither it scrolls the target into view (centred). A missing target fails the capture.
- Every local asset a screen references (stylesheet, script, image, CSS `url()`) must resolve, after symlinks, inside the walkthrough slug dir (the parent of `screens/`); a ref that escapes it fails the capture.
- Duration is derived, never authored: `duration_ms = max(min_ms, measured_ms + pad_ms)`. A `duration_ms` key on a scene or in `timing` is a validation error. `measured_ms` is written by the renderer from the narration alignment.
- Every scene `hypotheses` id resolves to the top-level list; every scene has at least one requirement or one assumption.
- `store` is optional. `seed` must exist under `data/`. `from_scene` names an earlier scene (lower `order`), so there are no cycles. The starting state is the seed, then the `from_scene` end state, then the `patch` ops (`set`, `push`, `delete`). `prng_seed` is an integer, derived from the scene id when absent.
- `deps` keys are recomputed and compared. A stale key is reported, not silently fixed; `--fix` rewrites them. A `frames_key` of `null` means a `from_scene` dependency has not been captured yet.
- Narration is present tense, as a shipped product, with no concept framing. Provenance goes in `requirements` and `assumptions`, never in narration.

## Keys

All keys are sha256 hex over canonical JSON (sorted keys, no whitespace).

- `frames_key` (compose scene): the compose spec, the template version, the source scene's frames key, and the same capture fields as a live scene.
- `frames_key` (live scene): URL, devices with their specs, layout, the persona name and login spec (env names, never values), the session parent's frames key, interactions, `wait`, `storage`, viewport, fps, the derived duration, `browser`, the browserless image digest, and the live capture version. It recaptures only with `--recapture` or `--scene` (which pulls in its `session_from_scene` dependents).
- `frames_key`: screen html sha256, the inlined screen with every local asset, `tokens_css_sha256`, interactions, viewport, fps, the browserless image digest, the capture script version, the derived duration, the seed sha256, the mock-store.js sha256, the resolved starting state, and `prng_seed`.
- `audio_key`: narration text, voice id, model, output format, and voice settings.
- `asset_key` (images): prompt, model id, size, quality, and reference image digests.
- `broll_key` (ai-broll): source image digest, prompt, seconds, model id, resolution, and aspect ratio. An ai-broll scene's `frames_key` hashes the clip key (or, for a fallback, the source image digest and mode), the viewport, fps, frame count, and the FFmpeg image digest.
- `music_key`: the music block and the total timeline duration.
- `manifest_hash`: sha256 of manifest.json in canonical form, excluding the hash itself.
