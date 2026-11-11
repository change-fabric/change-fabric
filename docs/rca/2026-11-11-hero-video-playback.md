# Homepage walkthrough video does not play on iPhone

Date: 2026-11-11

## Summary

The 45-second walkthrough embedded on the homepage did not play in Safari on
an iPhone. A tap on the play button showed the native player in its playing
state at 00:00 / 00:00, and the video never loaded. The media file and its
HTTP delivery were sound; the fault was in how the click-to-load slot started
playback. The embed was also untidy on phones: a duration badge overlapped
the poster's own content and a separate full-width button sat below it.

## Impact

Every visitor on iOS Safari (and, by extension, any iOS browser, since they
share WebKit) who tried to play the homepage walkthrough got a stuck player
and no video. Desktop Chrome played it. No other page or asset was affected,
and the transcript disclosure kept working, so the content stayed readable.
The window runs from the production deploy of site/v0.13.0 and site/v0.13.1
on 2026-11-11 (deploy run finished 21:57:09 UTC) until the site/v0.13.2
deploy that carries this fix.

## Timeline (UTC)

- 2026-11-09 20:59: the click-to-load media slot merges (#351).
- 2026-11-09 21:36: the homepage gains the walkthrough slot (#354).
- 2026-11-11 21:54: the recut walkthrough merges (#365).
- 2026-11-11 21:55: site/v0.13.0 and site/v0.13.1 are tagged; their deploy
  runs start at 21:55:43 and 21:55:45 and succeed by 21:57:09.
- 2026-11-11, shortly after: a maintainer on an iPhone reports the stuck
  player and the cluttered embed.
- 2026-11-11 22:16: investigation confirms the bytes and headers are sound
  and starts the code fix in this change.

## Detection

A maintainer noticed it by hand on an iPhone. No monitoring, CI step, or
post-deploy check exercised playback.

## Root cause

Confirmed, the media is not the cause:

- `curl -I` on `/media/0d14a86ac4e6.mp4` returns 200, `content-type:
  video/mp4`, `accept-ranges: bytes`, and an immutable cache header; a
  `Range: bytes=0-1` request returns 206 with `content-range: bytes
  0-1/2007267`, which is what iOS Safari probes first.
- `ffprobe` in the dockerized ffmpeg image reports H.264 High profile level
  5.0, yuv420p, 1920x1080 at 30 fps, AAC LC 48 kHz stereo, 44.0 s, and a box
  order of `ftyp`, `moov`, `free`, `mdat` (faststart). A full decode logs no
  errors. All of this is within what iOS Safari plays.
- In the browserless Chrome image (which has an H.264 decoder), the
  production page plays after a click: `readyState` 4, `currentTime` 4.7 s
  after 5 s, no media error.

Inferred, the cause is the 0.13.1 slot's start sequence, which iOS Safari
does not honor. Before the click there was no media element; the click set
React state, which mounted a new `<video>` with a `<source>` child and
`preload="none"`, and a `useEffect` then called `focus()` and `play()` on it.
iOS Safari ties playback to the user gesture and to resource selection on
the element the gesture targets; a play request made from an effect on a
just-inserted element with deferred `<source>` selection left the player in
the playing state with no data, which matches the reported 00:00 / 00:00.
This could not be reproduced directly because no WebKit with H.264 runs in
the dockerized tooling. Supporting evidence: the same old build in the
open-source Chromium container also ends with `paused` false, `readyState` 0
and no error surfaced, while the fixed build there reports a media error and
shows its unavailable note, so a failure is no longer silent.

## Contributing factors

- The media went live on an HTTP 200 check only. Nothing played it on a real
  device or in browserless before or after the deploy.
- `verify/media.mjs` runs in open-source Chromium, which has no H.264
  decoder, so it accepts the "Video unavailable" fallback as a pass and never
  proves playback of the real file.
- No mobile Safari coverage exists anywhere in CI or review; the review
  looked at desktop screenshots.
- The silent stuck state: a play request that never loads raises no error,
  so the slot's own unavailable note never appeared.

## Resolution

The slot now renders one `<video>` (or `<audio>`) from the first render with
no src and `preload="none"`, so it still fetches no media bytes before the
click. The click handler sets `src` and calls `play()` on that element
inside the tap, then moves focus to it; captions mount with the click. A
unit test guards that shape. The embed now shows the poster filling a frame
at the media's aspect ratio with one centered play button, and a caption
under it with the runtime and a description, with no badge over the poster.
Site version 0.13.2. No media re-upload or CDN invalidation is needed, since
the bytes did not change.

## What went well

- The content-hashed, immutable media made the file easy to rule out: one
  download, one ffprobe, one range request.
- The transcript disclosure kept the content available during the outage.
- The click-to-load design meant the fix changed no media and no bytes
  budget.

## Action items

- Site maintainer: add a playback step to site CI that drives the
  browserless Chrome image (with H.264) against the fixture build and
  asserts `play()` resolves, `currentTime` advances, and `readyState` is at
  least 3.
- Release owner: add a post-deploy smoke test to the site deploy workflow
  that requests each manifest `/media/` URL, asserts the content type, a 206
  on a range request, and a faststart box order, then plays the homepage
  video in browserless Chrome.
- Site maintainer: add a WebKit run (Playwright WebKit in a container) to
  the media verification so a Safari-family engine exercises the click path.
- Release owner: add "play the homepage video on a phone" to the site
  release checklist in RELEASING.md until the automated checks land.
- Walkthrough owner: render a phone-legible poster on the next walkthrough
  render; the current one is a desktop diagram that is small at 375px.
