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
  "viewport": { "w": 1920, "h": 1080 },
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

`voice.pronunciations` is an optional list of aliases, `[{ "text": "CHANGE.md", "say": "change dot M D" }]`: the voice speaks `say` wherever `text` appears, while the narration text and the captions keep `text` (caption timing follows the spoken alias). Each `text` and `say` is a non-empty string and each `text` appears once. They become an ElevenLabs pronunciation dictionary of alias rules, created once per distinct rule set (cached under `.cache/pronunciation/` by content hash, no charge) and sent with every narration request; verified on `eleven_multilingual_v2`. Aliases are part of `audio_key`, so adding or changing one re-voices every narrated scene.

`music.start` is optional seconds from the video's start (default 0, >= 0 and below the total length); `music.fade_in` is optional seconds (default 0, 0..2). Silence plays before `start`; the bed is generated for `total - start` (an unset `start` keeps the cache key), delayed to `start`, then faded in. Music duck spans keep their absolute times. Example: `"music": { "prompt": "string", "start": 3.9, "fade_in": 0.05 }`.

`voice.eq` is optional narration EQ applied to the narration bus before the music duck: `"warm"` or `{ "low_shelf_hz": 150, "low_shelf_db": 3, "cut_hz": 3500, "cut_db": -2.5 }` (each hz/db pair optional but all-or-nothing, 20-20000 Hz, +-24 dB); it changes the manifest hash and so re-assembles, never `audio_key`.

`music` may be `null` for a narration-only walkthrough.

`viewport.dpr` is optional. When it is absent, every capture (prototype, environment, live, compose) derives it per scene from the slot the desktop fills on the scene's stage: the stage is the canvas times `camera.zoom` when it magnifies (or 1.12x for a hero still's push-in), and the slot is that stage inside any browser frame. The dpr is the least integer that fills the slot to within 1.05x, clamped to 1..4: an unzoomed full-bleed scene stays at dpr 1, a 1.5x zoom captures at dpr 2. A phone's `dpr` is a floor the same rule can raise, and every device of a scene captures at the scene's largest dpr, which is also the scale the browser is launched at (headless Chromium's screencast and raw screenshots ignore an emulated dpr otherwise). Frames are stored on the stage and only ever scaled down before the camera crops, so no scene upsamples small text. Captures run with grayscale text antialiasing (LCD subpixel fringes smear under 4:2:0 chroma) and with the page's own cursor hidden, so the composited sprite is the only cursor. An explicit `dpr` always wins; pin `"dpr": 1` only when a soft zoom is acceptable. Every render prints a sharpness line from `scripts/walkthrough_sharpness.rb`: a capture stretched more than 1.05x into its slot (only possible under a pinned dpr) is listed as a warning. The derived dpr and the stage are in every `frames_key`, so changing a zoom recaptures. A crossfade parks the outgoing scene's cursor for the overlap, so two cursors never show at once.

A scene's `camera` is `{ "zoom": <0.5..3>, "focus": { "x": <0..1>, "y": <0..1> } }`. `zoom` is required; `focus` is optional and defaults to the frame centre (0.5, 0.5), the point the zoom scales around.

Live capture runs open-source Chromium, which cannot decode H.264 video or AAC audio. A `<video>` or `<audio>` it cannot play is reported by the UX lint as `unplayable-media` and blocks `--final`; serve a VP9/Opus or AV1 transcode at the same path for filming.

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
  "narration_start": 0,
  "sfx": { "file": "sfx/riser.wav", "start": 0.0, "gain_db": -18, "duck_db": -10, "duck_lead": 0.1 },
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
- The single `device` field takes one value only, `"device": "phone-fullbleed"`, for vertical output (such as a 1080x1920 viewport); any other value is rejected in favor of `devices` and the board `phone` spec. It takes no `devices` or `layout`, and no browser `frame` or `inset` (both film the desktop only).
- A `phone-fullbleed` scene is filmed frameless: captured at the board's `"phone_fullbleed": { "w": 390, "h": 693 }` CSS viewport (`w` defaults to 390, `h` to the canvas aspect at that width, so 693 on 1080x1920; each an integer in 100..4000, such as 430x764, and `h` must stay within 1 percent of the canvas aspect) with the phone `ua` and mobile emulation, at a dpr of stage width over `w` (1080/390, about 2.769), and scaled edge to edge: no bezel, mat, or caption band. Captions overlay a smooth bottom scrim: one continuous alpha ramp of the bezel ink over the bottom 24 percent, clear at the top to 60 percent at the bottom, with no bands (board `captions.scrim`, below). The cursor and tap ripple grow by the canvas px per CSS px (2.769 by default). Its frames key carries layout `fullbleed` and the spec.
- `"captions": { "scrim": "gradient", "burn": true }` is an optional board block. `scrim` is `gradient` (default) or `none`. The scrim is only drawn in `phone-fullbleed` scenes; every other layout renders as before. With `none` there is no scrim, and captions burned with `--burn-captions` get a libass outline and drop shadow instead (`force_style` Outline=2, Shadow=1). `burn` is true or false (default true): false writes sidecar captions only (`captions.srt` and `walkthrough.vtt` beside the MP4), with no burned text and no `mov_text` track, even under `--burn-captions`. Without `--burn-captions` captions are never burned; the MP4 carries a soft `mov_text` track plus the same sidecars. Other keys are a validation error.

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

### Environment scenes

`"kind": "environment"` shows a simulated, neutral desktop from the desktop kit in `skills/prototype/fixtures/desktop/` (its `CONTRACT.md` lists every window type and fixed id). Nothing on a real machine is touched. The kit owns the chrome; the project owns the content through the scene's seed.

```json
{ "id": "install", "order": 4, "kind": "environment", "screen": { "html": "screens/install.html" },
  "store": { "seed": "data/install.json" },
  "environment": { "open": ["explorer", "services"], "focus": "explorer", "slots": { "docs-content": "screens/partials/docs.html" } },
  "interactions": [{ "t_ms": 0, "op": "dblclick", "target": "#explorer-file-install-agent-bat" },
                   { "t_ms": 600, "op": "click", "target": "#elevate-yes" }] }
```

- `store.seed` is required and follows `desktop.schema.json`: `windows[]` (`id`, `type`, `title`, `x`, `y`, `w`, `h`, plus per-type fields), `files[]`, `downloads[]`, `services[]`, `terminal.transcript[]`, `editor.documents[]`, and `clock`. Window types: browser, file-explorer, text-editor, terminal, elevation-prompt, services-list.
- `environment.open` lists the windows visible at the start (default all); the rest render hidden and can be opened in the scene (a file row double-click, an elevation Yes). `focus` must be an open window (default the last one). `slots` maps a browser window's `<id>-content` slot to a project HTML partial.
- Run `ruby scripts/walkthrough_environment.rb storyboard.json` to write each `screen.html`. Validation fails on drift (the screen's ids differ from the kit's) and on a stale file. The kit `VERSION` is part of the scene's `frames_key`.
- ASSUMPTIONS.md lists each one under Simulated UI as a simulated desktop environment.

### Browser frame

`"screen": { "frame": "browser" }` on a live or environment scene films the captured viewport inside a neutral, unbranded browser window: a tab with `screen.title` and an address bar with `screen.address`, on a plain desktop canvas, scaled to fit above the caption band with the viewport's aspect ratio.

```json
{ "id": "docs", "order": 1, "screen": { "url": "https://docs.example.test/northwind-agent", "frame": "browser", "title": "Northwind Agent docs" } }
```

- `address` defaults to a live scene's `screen.url`; an environment scene must give it. `title` defaults to the address host. Both are single-line strings of at most 200 characters, clipped with three dots to fit the bar.
- The frame films the desktop only: no `devices` other than desktop and no `layout`. `title` or `address` without `frame` is an error.
- Compositing is offline in the pinned FFmpeg container (`scripts/walkthrough_browser_frame.rb`); the cursor track is mapped into the window. A live scene is framed while its screencast is composited; an environment scene is framed in place right after capture.
- The frame (title, address, compositor version, FFmpeg digest) is part of the scene's `frames_key`, so changing any of them recaptures.

### Magnified inset

`inset` on a live scene magnifies one small element (a badge, a figure, a source line of 8 to 11 px at 1080p) the viewer must read, without a camera zoom: the device or browser frame keeps its size, so the device-frame rule still holds.

```json
{ "id": "report", "order": 4,
  "screen": { "url": "https://app.localhost/report", "frame": "browser" },
  "inset": { "selector": "[data-test=source-line]", "at_ms": 1200, "duration_ms": 2500, "scale": 2.5, "position": "top-right" } }
```

| Field | Type | Default | Rule |
|---|---|---|---|
| `selector` | string | required | CSS selector; its first match is magnified. A selector that matches nothing at `at_ms` fails the capture. |
| `at_ms` | integer | required | Non-negative; the element box is read on that frame and the inset starts there. |
| `duration_ms` | integer | required | 600..15000; the window is clipped to the scene's end. |
| `scale` | number | 2.0 | 1.25..4; lowered to fit when the magnified box would leave the safe area. |
| `position` | string | `top-right` | One of `top-right`, `top-left`, `bottom-right`, `bottom-left`. |

- The scene must be live (`screen.url`) and film the desktop only; `inset` with `camera.zoom` above 1 is an error.
- At capture the desktop run records the element's bounding box (viewport CSS px, padded by 6 px). The box maps to the canvas through the scene's own frame layout (`walkthrough_browser_frame.rb` or `walkthrough_device.rb`), so a browser frame is accounted for.
- At `at_ms` the capture also screenshots that padded region at `scale` times the device pixel ratio (CDP `clip.scale`), and the inset is drawn from that still, so it reads crisp instead of as an upscaled 1x crop. If that capture fails, the composite falls back to upscaling the crop and prints a warning; `inset.json` records which path ran (`hires`).
- The composite crops that region from every captured frame and overlays it magnified with a 3 px border and a 200 ms alpha fade in and out, in a corner of the safe area: 4% of the canvas height from the edges and above the caption band. Fades count frames, so the output is deterministic (`scripts/walkthrough_inset.rb`).
- The inset is drawn after the in-page UX lint ran, so it never enters the lint; its on-canvas region is written to `inset.json` beside the frames.
- The inset spec and its compositor version are part of the scene's `frames_key`.

## Diagram scene

`"kind": "diagram"` is a full-frame node and edge diagram (React Flow, vendored as `scripts/vendor/xyflow/xyflow-<version>.min.js`, driven by `cf_diagram_runtime.js`) that assembles and moves under the capture clock. It is a prototype screen: `screen.html` is required and generated, and live-only keys are refused. Worked example: `test/fixtures/walkthrough/diagram-lr/storyboard.json`.

```json
{
  "id": "pipeline", "order": 1, "kind": "diagram", "title": "Request path",
  "screen": { "html": "screens/pipeline.html" },
  "diagram": {
    "layout": { "engine": "dagre", "direction": "LR" },
    "nodes": [
      { "id": "client", "label": "Browser", "role": "accent" },
      { "id": "gateway", "label": "Gateway" },
      { "id": "db", "label": "Postgres", "role": "muted", "position": { "x": 600, "y": 200 } }
    ],
    "edges": [
      { "id": "e1", "source": "client", "target": "gateway", "label": "HTTPS" },
      { "id": "e2", "source": "gateway", "target": "db", "label": "writes" }
    ],
    "initial": ["client", "gateway", "e1"],
    "steps": [
      { "t_ms": 400, "op": "add_node", "ids": ["db", "e2"] },
      { "t_ms": 900, "op": "fit_view", "padding": 0.1, "duration": 600 },
      { "t_ms": 1800, "op": "highlight", "ids": ["db", "e2"] },
      { "t_ms": 2000, "op": "focus", "id": "db", "zoom": 1.5, "duration": 400 }
    ]
  },
  "narration": { "text": "string" }, "assumptions": [{ "id": "A-01", "text": "string" }],
  "timing": { "min_ms": 2600, "pad_ms": 0, "transition": { "type": "cut", "ms": 0 } }
}
```

The `diagram` block takes only `layout`, `theme`, `lanes`, `lane_direction`, `report`, `nodes`, `edges`, `initial`, and `steps`; any other key fails validation.

- `layout` (optional): `engine` is `dagre` (default) or `manual`; `direction` is `TB`, `LR` (default), `BT`, or `RL`; `max_zoom` (0.5..2.0, default 1.25) is how far the opening fit and every `fit_view` may enlarge the picture, so a small diagram can fill a large frame with nodes, icons, labels, and edges scaled together (it also lifts the `focus` cap when above 1.5). dagre lays out the full node set once, so a later `add_node` never reflows the rest, and nodes in one rank keep their spec order. Under `manual`, a node without `position` sits at 0,0.
- `theme` (optional): `light` (default) or `dark`, which theme of the palette the screen draws in (see Theme).
- `report` (optional, needs horizontal lanes): the results panel; see Swimlanes.
- `lanes` (optional): 0 to 8 (`MAX_LANES`) swimlanes, `{ "id", "label", "color", "icon", "icon_weight" }` (only those keys; `label` a non-empty string; `color` as in Item colours, default `series-N` by position), drawn as bands in spec order. `lane_direction` (optional, needs `lanes`): `horizontal` (default, full-width rows) or `vertical` (full-height columns). See Swimlanes.
- `nodes`: 1 to 12 (`MAX_NODES`). `id` (required), `label` (required, non-empty string), `role` (`default`, `accent`, or `muted`), `color` (optional, see Item colours), `icon` and `icon_weight` (optional, see Node icons), `lane` (optional, a lane id; see Swimlanes), and `position` (`{ "x": <number>, "y": <number> }`, exactly those two keys, pins the node's top-left even under dagre). Node size comes from the spec, never measurement: height 56, width from the longest text the node ever shows (its label or any `label` step), clamped to 140..260, plus 28 when the node has an icon.
- `edges`: 0 to 16 (`MAX_EDGES`). `id`, `source` and `target` (node ids), an optional `label` string, and an optional `color` (see Item colours). Arrowheads and sides (left/right or top/bottom) follow the node positions each frame.
- Ids match `[a-z0-9][a-z0-9-]*` and are unique across nodes, edges, and lanes together; steps name any of them by id. The id `constructor` is reserved too (it names a JavaScript object property). Ids beginning `__cf_` are reserved for nodes the lane layer adds itself (its camera anchors); the id rule rejects them, and every authored id, so the two never collide.
- `initial`: node and edge ids visible at time 0. Everything else starts hidden until an `add_node` or `connect` shows it, so an empty `initial` starts on a blank frame.
- `steps`: `t_ms` is a non-negative integer, non-decreasing, and below the scene's derived duration. `duration` (optional on any op) is a non-negative integer in ms; a camera or move step with no duration jumps. Tweens ease in and out (cubic).

Ops (closed set, `WalkthroughDiagram::DIAGRAM_OPS`). Ops marked "id or ids" take `id` or a non-empty `ids` list, never both.

| op | Fields | Targets | Effect |
| --- | --- | --- | --- |
| `add_node` | id or ids | nodes, edges, lanes | Fades in over 300 ms (cancels an earlier `remove`). |
| `connect` | id or ids | edges | Fades the edge in, as `add_node`. |
| `remove` | id or ids | nodes, edges, lanes | Fades out over 300 ms. |
| `highlight` | id or ids | nodes, edges, lanes | Accent border and halo, or accent stroke and arrowhead; a coloured item keeps its own colour (border with a ring of it, or a thicker stroke); a lane's band brightens to its highlight tint; clears `dim`. |
| `dim` | id or ids | nodes, edges, lanes | Opacity 0.35; clears `highlight`. |
| `unhighlight` | id or ids | nodes, edges, lanes | Clears both `highlight` and `dim`. |
| `pulse_edge` | id or ids, `duration` (default 800) | edges | The stroke swells and settles once, highlighted while it runs. |
| `flow` | id or ids, `color` (optional), `count` (1..8, default 3), `duration` (per dot, default 1200), `stagger` (ms between dots, default `duration / count`), `repeat` (default 1) or `loop: true` | edges | Small glowing dots glide along the edge from source to target, eased in and out, in the accent colour with an accent-tint halo, or in the edge's `color` with its tint when the edge has one; a `color` on the step overrides both. Placed on the edge's drawn path each frame from the capture clock (not SVG or CSS animation), so they follow the edge when a node moves. `loop` runs to the scene's end; `repeat` replays the batch. |
| `move` | `id`, `position` `{x, y}`, `duration` | node | Tweens the node to the new top-left. |
| `label` | `id`, `text` (string) | node | Replaces the node's text; the width was sized for it already. |
| `fit_view` | `ids` (optional), `padding` (0..1, default 0.2), `duration` | nodes | Fits the camera to `ids`, or to the nodes visible when the step ends; zoom at most 1.25, or `layout.max_zoom`. |
| `zoom_to` | `zoom` (0.2..3, required), `duration` | none | Zooms about the current view centre. |
| `focus` | `id`, `zoom` (0.2..3, optional, keeps the current zoom), `duration` | node | Centres the node; zoom at most 1.5 (or `layout.max_zoom` when larger) when rendered. |
| `travel` | `lane` (required), `id` (optional node: the token), `result` (optional node), `duration` (positive, default 700), `easing` (optional, default `standard`) | lane, node | Carries the token (a pull request, say) along the lane's rail from the lane's entry to just past its last checkpoint; with no `id`, a glowing marker in the lane's colour travels instead. With `result`, a chip carries that node into its slot and the node settles there. See Swimlanes for the full beat. |

- Camera: the scene opens fitted to the `initial` nodes (or every node when none is initial) at padding 0.2. Each camera step (`fit_view`, `zoom_to`, `focus`) tweens from wherever the camera is when it starts, and every target is fitted and centred in the area above the caption band (the bottom 15 percent of the viewport, `PrototypeUxLint::CAPTION_BAND`), which the generator writes into the screen as `bottom_inset`.
- Gap: the caption inset applies to camera targets only. A node that moves or appears between camera steps can sit in the band until the next one, so follow a `move` or a late `add_node` with a `fit_view`.
- Theme: the screen's `--cf-*` colours come from the walkthrough's `tokens.css` (its own `screens/tokens.css` first, the one its screens link, else the canonical tokens file found by walking up) (the cf:diagram palette roles `--bg`, `--surface`, `--line`, `--rule`, `--ink`, `--muted`, `--accent`, `--accent-tint`, in the scene's `theme`), else a neutral placeholder for that theme. Validation fails on a token file DiagramPalette cannot read and on any pair in the scene's theme under the text contrast floor, including `--ink` on `--accent-tint` and `--muted` on `--bg` (node label text).
- Item colours: `color` on a node, an edge, or a `flow` step is a named role or a CSS colour (`#rgb`, `#rrggbb`, or `rgb(r, g, b)`); anything else, an unknown role, or `color` on a non-flow step fails validation. Prefer roles: they follow the theme. Roles (`WalkthroughDiagram::COLOR_ROLES`): `accent` (the palette accent), `success`, `warning`, `danger`, and a categorical `series-1` to `series-6` for lanes that should read apart. Each takes the first token `tokens.css` defines in the scene's theme (`--success`/`--ok`/`--positive`, `--warning`/`--warn`/`--caution`, `--danger`/`--error`/`--destructive`/`--negative`, `--series-N`/`--chart-N`/`--cat-N`), else a built-in default per theme. A coloured node draws its border in the colour on a tint of it over the surface (10 percent light, 14 dark) with its label in the theme's text colour; a coloured edge draws its stroke, arrowhead, and flow dots in it. Validation requires the label text on each tint to clear 4.5:1 (WCAG AA) and each colour to clear 3:1 against the surface. A spec with no `color` writes exactly the screen it wrote before; one with colours adds a `cf-diagram-colors` JSON block of resolved hexes. Worked example: `test/fixtures/walkthrough/diagram-colors/storyboard.json`.
- Node icons: `"icon": "git-pull-request"` draws that glyph inline as SVG before the label, 20px (the label's size) with an 8px gap, in the node's `color` or, on an uncoloured node, the label's colour. `icon_weight` is `regular` (default), `bold`, `duotone` (the second tone is the same colour at 20 percent opacity), or `fill`. Icons are a curated Phosphor (MIT) subset vendored as path data in `scripts/vendor/phosphor/phosphor-2.1.1.json` (`WalkthroughDiagram.icon_names`): check-circle, clipboard-text, cloud, code, database, device-mobile, devices, file-text, flow-arrow, gauge, gear, git-branch, git-commit, git-merge, git-pull-request, list-checks, lightning, lock, person-simple-circle, robot, rocket, seal-check, shield-check, stamp, tag, terminal, test-tube, user, users, warning, wheelchair, x-circle. An unknown name fails validation and lists these; to add one, add it to `PhosphorVendor::NAMES` and rerun `scripts/phosphor_vendor.rb`. The screen inlines only the glyphs its nodes use in a `cf-diagram-icons` JSON block, so nothing is fetched at capture; a spec with no icon writes exactly the screen it wrote before. A coloured node's icon must clear 3:1 on its tint. THIRD_PARTY_NOTICES carries the Phosphor notice when any `icon` sits anywhere in a diagram spec: on a node, a lane, or any later field that takes one. Worked example: `test/fixtures/walkthrough/diagram-icons/storyboard.json`.
- Swimlanes: each lane is a band across the whole frame (a column with `vertical`), tinted with its colour over the surface (5 percent, 11 while its lane runs or is highlighted), with 1 px dividers at 8 percent white (dark) or ink (light), and its name (22 px, weight 600, the theme's text colour, after a bar and any icon in the lane colour). Horizontal lanes lay out as one composition: a 280 unit name column, then the checkpoints, each drawn 224 units wide and left-aligned to its along coordinate, then the travel stretch, then the report panel when there is one. The lane layer computes one layout record of every box (nodes, lane names, bands over the travel stretch, each token from its entrance to its exit, the panel, standalone results), and two invisible corner nodes span its bounds in either direction, so the opening fit and any `fit_view` frame all of it (a `fit_view` at 0 with a small `padding` gives a tight, centred frame). Vertical lanes put the name, in the same style, 16 units above the column's first checkpoint, and a column grows to fit its name. Node text in a laned screen is 19 px, sized so a 1280 wide frame stays readable played back on a phone. A node with `lane` sits inside its band: it keeps its along coordinate (from dagre, or from `position`, whose other coordinate the band owns) and is centred on the band's cross axis, taking a new row when it would overlap a lanemate; a band is at least 120 units and grows to fit its rows. When the scene has any `travel`, each band reserves a rail under its checkpoints (8 units below them, then the 32 unit token with 17 px type, then 12 units of padding), so a token never passes through one. While its lane runs, each checkpoint takes a 1.5 px border in the lane colour with a 16 px glow at 12 percent; otherwise a quiet 1 px border, or its own colour if it has one. A `highlight` on the checkpoint itself wins over both: these styles are CSS keyed on the runtime's highlight state, never written over it. A node without `lane` keeps its pinned position, or under dagre is centred on the stack of bands. A lane shows from the start when `initial` names it, or when `initial` names no lane at all; `add_node`, `remove`, `highlight`, `dim`, and `unhighlight` act on lanes as on nodes. A travel spans from the first checkpoint's start to 16 units past the widest reach of the last, the same for every lane, so a token crossing each lane in turn reads as one route. One travel, anchored on its `t_ms` (t0) and `duration` (D): over the 130 ms before t0 the token reveals at the lane's entry, sliding 12 units right as it fades in, and the lane lights (120 ms); from t0 it rides the rail with its `easing` (`standard` is cubic-bezier(0.4, 0, 0.2, 1); also `linear`, `ease-in-out` (the runtime's cubic), `decelerate`, `accelerate`, `emphasized` (0.22, 1, 0.36, 1), `settle` (0.16, 1, 0.3, 1), or any `cubic-bezier(x1, y1, x2, y2)` with x1 and x2 in 0..1); each checkpoint it passes pulses 1 to 1.025 to 1 over 180 ms. With `result`, a chip appears at the token's exit over the last 100 ms, waits a 100 ms arrival tail, and transfers to the result's slot over 260 ms (`emphasized`); on landing the result card settles from 14 units above its slot over 220 ms (`settle`), fading in over the first 100, and the lane's light fades over 180 ms. A token travelling again leaves its lane as the next lane's entrance begins: it fades over 90 ms drifting 16 units right, starting 60 ms before the next reveal, so the two overlap by 30 ms and nothing slides back. A token's last travel holds at its end; a marker fades at its tail. The token and each result are drawn by the lane layer: they sit in no lane and no edge, are never in `initial`, and no other step names them (validation enforces this), and without `report`, a result's `position` is its reserved slot, so place slots far enough apart that a 14 unit drop never touches a neighbour. With `report` (`{ "label": "Report", "unit": "checks" }`, horizontal lanes only; `unit` defaults to `checks`), results land instead as uniform rows in an opaque panel right of the lanes (fill #111c2d dark, 1 px border at 8 percent, 14 px radius, 24 px padding, the label as its heading); each row shows the result's label, a dot in its lane's colour, and the lane's name in the muted colour, rows 18 units apart so a drop never touches the row above, and the lane fills stop short of the panel. As the last result lands the heading gains a neutral `N/N <unit>` badge (a count of results delivered, not a verdict); 800 ms after that landing, or after the token's own last ride if it ends later, the token fades over 120 ms and the panel border swells once over 180 ms, then rests. For about a 1.4 s lane rhythm, start travels 1400 ms apart with `duration` 700, so each entrance falls inside the previous lane's fade. Explicit `highlight` and `unhighlight` on a lane fade the same way (120 ms in, 180 ms out). Custom easing is for `travel` only; `move` keeps the runtime's cubic, because the runtime is shared with every screen. Bands are drawn behind the diagram and tokens, chips, and result cards in front of it, each frame from the camera and the capture clock (no CSS or SMIL animation). A lane `icon` (with `icon_weight`, the same names and vendored data as Node icons) draws before its label in the lane colour, and must clear 3:1 on its band at rest and highlighted. Validation requires each lane label to clear 4.5:1 on its band at rest and highlighted, and the lane colour to clear 3:1 on the surface. A spec with no `lanes` writes exactly the screen it wrote before; one with lanes adds a `cf-diagram-lanes` JSON block and inlines `scripts/vendor/xyflow/cf_diagram_lanes.js` (which lays the lanes out before the runtime reads the spec) between the bundle and the runtime. Worked example: `test/fixtures/walkthrough/diagram-swimlanes/storyboard.json`.
- Lane text budgets: every text the lane layer draws is sized from the spec by one estimate (`scripts/diagram_text_fit.rb`, mirrored in the lane layer) at the font the box is drawn in, never measured at render time. Each character takes the em share of its class, set at or above the widest glyph of that class in the pinned browserless Chromium's system-ui at weight 600: 0.5 for narrow glyphs (space, i, j, l, t, r, f, and thin punctuation), 0.88 for wide capitals (A, B, D, G, H, K, N, O, Q, R, U, V, X, and some symbols), 1.11 for m, w, M, W, @, and %, 1.0 for CJK, and 0.74 for anything else. Each box has one rule, and a spec that breaks it fails validation; nothing is cut off. A checkpoint label (a laned node in horizontal lanes, its label or any `label` step) is 19 px and wraps at spaces, or anywhere inside a word too long for a line, into at most 2 lines of 196 px (168 with an icon); the card grows to fit (23 px lines, 6 px padding above and below, never under 56). A token label is 17 px on one line of at most 196 px (174 with an icon). A lane label is 22 px on one line of at most 248 px (218 with an icon). A report row holds its result's label at 18 px and its lane's name at 15 px on one line of 328 px together. The report heading holds its label at 22 px and the `N/N <unit>` badge at 16 px plus 32 px of badge room on one line of 390 px. At 0.74 em that is about 13 ordinary characters a checkpoint line, 15 token characters, and 15 lane label characters. Validation names the box, the text, its estimated width, and the budget.
- Generation: `ruby scripts/walkthrough_diagram.rb storyboard.json [--scene ID]` writes each diagram `screen.html` (marked GENERATED: the bundle, the runtime, the palette, and the spec as JSON). `validate --fix` rewrites them; validation reports a screen that differs as drift. `render-md` lists lanes and nodes (icons, pinned and laned ones marked), edges, the initial set, and a step table.
- Determinism: the runtime derives each frame as a pure function of the capture clock, and the capture waits on `window.__cfDiagramReady` before frame 0 (it fails after 15 s with the runtime's last status rather than film a blank frame).
- Notices: `walkthrough_assumptions.rb` adds xyflow (React Flow), React, React DOM, and dagre with their versions and licences, a note that the React Flow attribution badge is hidden by choice, and every bundled licence text to `THIRD_PARTY_NOTICES` whenever a diagram scene exists.

## Rules

- `id` matches `\A[a-z0-9][a-z0-9-]*\z` and is unique; `order` is unique and contiguous from 1.
- `timing.transition` is the move into a scene: `{ "type": "cut" | "fade" | "crossfade" | "slide-left" | "slide-up" | "push", "ms": 350, "ease": "linear" | "ease-in" | "ease-out" | "ease-in-out" }`. Every type but `cut` overlaps the previous scene by `ms` (100..1500). `fade` needs `ms` and, without `ease`, is the original linear crossfade, rendered exactly as before; with `ease` it is a `crossfade`. For the other types `ms` defaults to 350 and `ease` to `ease-in-out` (cubic curves; `linear` is the only straight one). `crossfade` blends the two pages; `push` slides the old page out left while the new one slides in from the right, together, like native navigation; `slide-left` and `slide-up` slide the new page in over the old one, which stays still. An optional top-level `"transition"` with the same keys is the board default for every scene after the first; a scene's own `timing.transition` wins. Each renders as an FFmpeg xfade custom expression (the pinned 7.1 xfade has no easing of its own). During the overlap the outgoing scene's cursor and tap ripples are parked off canvas and the incoming ones move with their page; narration, captions, and music keep the timeline's scene starts.
- `op` is one of move, click, dblclick, type, key, hover, scroll, wait, tap; `t_ms` is a non-negative integer and non-decreasing; `target` is required except for wait and key.
- `dblclick` double-clicks `target` (a real two-press mouse sequence), for opening a file or a list row.
- `key` presses `keys` on its frame through CDP key events under the virtual clock: one key (`"Enter"`, `"Escape"`, `"a"`) or a chord with modifiers first (`"Control+C"`, `"Control+Shift+Esc"`). Modifiers are Control, Shift, Alt, Meta; `Ctrl`, `Cmd`, `Option`, `Esc`, `Return`, `Del`, and `Space` are aliases. An optional `target` is focused first. An unknown key fails validation.
- `scroll` takes a `target`. With integer `dx` and/or `dy` it scrolls that element by those pixels, instantly, so the same delta gives the same frame; with neither it scrolls the target into view (centred). A missing target fails the capture.
- A `scroll` with `ms` glides instead, like a finger scroll in a screen recording: `{ "t_ms": 0, "op": "scroll", "target": "html", "dy": 220, "ms": 900, "ease": "ease-in-out" }`. `ms` is an integer in 1..10000 and needs `dx` or `dy`; `ease` is one of linear, ease, ease-in, ease-out, ease-in-out (the real CSS cubic-bezier curves, default ease-in-out) and needs `ms`. Each frame over `ms` sets the target's scroll offset to its origin (read on the glide's first frame) plus the eased share of the delta, rounded to 0.01 px, the last frame at the full delta, so the same board gives the same offsets on every frame. `target: "html"` scrolls the page. A scroll without `ms` keeps the instant jump.
- `tap` presses `target` like a finger: on its frame the target takes a pressed look (scale 0.96, opacity 0.82, injected CSS only into a page that taps) and the ripple starts there; after `press_ms` (an integer in 1..1000, default 120) the look lifts and the real click lands (a touch tap on a phone, a mouse click on a desktop), and the frames after it show the page's own response. A press longer than the scene releases on its last frame.
- `"navigate": true` on a tap (default false) carries it straight into the next scene. It is the last op of a live scene, releases after every other tap in it, and sits in the first device's list (whose session the scene hands on); the next scene by order is a live scene with `session_from_scene` naming the tapping scene, and no other scene starts from that session. The tapping scene's end session records the page URL the tap reached and the tap point; the next scene fails the capture unless its `screen.url` is that URL, and starts its cursor (and so any ripple) at the tap point, so the cut reads as one motion. The cut between them is the next scene's own transition: `timing.transition` today (a cut, or a fade that overlaps the tapping scene's last frames, which already show the navigated page), and a scene `transition` key the same way once it exists; navigate adds no transition of its own. `ms`, `ease`, `press_ms`, and `navigate` on any other op fail validation. All four keys are in the interactions, so they are in every frames key; a board without them plans and keys exactly as before.
- Every local asset a screen references (stylesheet, script, image, CSS `url()`) must resolve, after symlinks, inside the walkthrough slug dir (the parent of `screens/`); a ref that escapes it fails the capture.
- The music bed ducks under each scene's spoken span, on every board by default: `timing.music_duck_db` is the depth (default -8, a number in -60..0), `timing.music_duck_attack_ms` ramps it down before speech starts so the bed is fully down when the first word lands (default 300, an integer in 0..2000), and `timing.music_duck_release_ms` ramps it back up after the last word (default 500, 0..2000). All three are optional overrides. Ramps are linear in dB; spans closer together than one release plus the next attack merge into one duck at the deeper level, so the bed never pumps between close lines. The duck shape is versioned in the manifest, so a change to it re-assembles without re-narrating.
- `narration_start` (seconds, default 0, a number in 0..60) starts the scene's voice line that far into the scene. The narration track, the caption cues, and the music duck spans all shift by it. It needs `narration.text`; the scene grows to fit it (below), so a value that cannot fit is a validation error that names the value.
- `sfx` mixes one sound effect under the narration and music, on the timeline from its scene's start. Only `file` is required: a `.mp3`, `.wav`, `.m4a`, `.aac`, `.ogg`, or `.flac` path relative to the storyboard and inside the walkthrough directory, the same rule as `broll.source_image`. `start` (default 0.0, seconds into the scene, >= 0), `gain_db` (default -18, -60..12), `duck_db` (default unset, -60..0), `duck_lead` (default 0.1, seconds, 0..2). The effect is cut at its scene's end. With `duck_db` set it ducks under every narration span through the same ramped duck as the music (300 ms attack, 500 ms release, close spans merged), each span starting `duck_lead` earlier; unset, it never ducks. Unknown keys fail validation. The manifest pins the file's sha256, so editing the effect in place re-assembles. Example, a riser under a late line: `"narration_start": 4.0, "sfx": { "file": "sfx/riser.wav", "gain_db": -17, "duck_db": -10 }`.
- Duration is derived, never authored: `duration_ms = max(min_ms, narration_start_ms + measured_ms + pad_ms)`. A `duration_ms` key on a scene or in `timing` is a validation error. `measured_ms` is written by the renderer from the narration alignment.
- Every scene `hypotheses` id resolves to the top-level list; every scene has at least one requirement or one assumption.
- `store` is optional. `seed` must exist under `data/`. `from_scene` names an earlier scene (lower `order`), so there are no cycles. The starting state is the seed, then the `from_scene` end state, then the `patch` ops (`set`, `push`, `delete`). `prng_seed` is an integer, derived from the scene id when absent.
- `deps` keys are recomputed and compared. A stale key is reported, not silently fixed; `--fix` rewrites them. A `frames_key` of `null` means a `from_scene` dependency has not been captured yet.
- Narration is present tense, as a shipped product, with no concept framing. Provenance goes in `requirements` and `assumptions`, never in narration.

## Keys

All keys are sha256 hex over canonical JSON (sorted keys, no whitespace).

- `frames_key` (compose scene): the compose spec, the template version, the source scene's frames key, and the same capture fields as a live scene.
- `frames_key` (live scene): URL, devices with their specs, layout, the browser frame when set, the inset when set, the persona name and login spec (env names, never values), the session parent's frames key, interactions, `wait`, `storage`, viewport, fps, the derived duration, `browser`, the browserless image digest, and the live capture version. It recaptures only with `--recapture` or `--scene` (which pulls in its `session_from_scene` dependents).
- `frames_key`: screen html sha256, the inlined screen with every local asset, `tokens_css_sha256`, interactions, viewport, fps, the browserless image digest, the capture script version, the derived duration, the seed sha256, the mock-store.js sha256, the resolved starting state, and `prng_seed`; an environment scene adds the desktop kit `VERSION` and the browser frame when set; a diagram scene adds the xyflow bundle sha256 and the diagram runtime sha256.
- `audio_key`: narration text, voice id, model, output format, voice settings, and `voice.pronunciations` when present.
- `asset_key` (images): prompt, model id, size, quality, and reference image digests.
- `broll_key` (ai-broll): source image digest, prompt, seconds, model id, resolution, and aspect ratio. An ai-broll scene's `frames_key` hashes the clip key (or, for a fallback, the source image digest and mode), the viewport, fps, frame count, and the FFmpeg image digest.
- `music_key`: the music block and the total timeline duration.
- `manifest_hash`: sha256 of manifest.json in canonical form, excluding the hash itself.
