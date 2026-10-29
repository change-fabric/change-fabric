# cf:walkthrough manual release check

CI runs validation and argv golden tests only, with no docker and no network. This end-to-end run is the manual release check. It uses real keys, the pinned browserless and FFmpeg containers, and costs a few cents (print the estimate first).

## Runbook

Run against a scratch copy, because the renderer writes measured narration and deps back into storyboard.json and would otherwise change the committed fixture and its goldens.

```
cp -r test/fixtures/walkthrough/greenfield "$SCRATCH/greenfield"
ruby scripts/walkthrough_render.rb "$SCRATCH/greenfield" --final --estimate-only
ruby scripts/walkthrough_render.rb "$SCRATCH/greenfield" --final
```

Keys come from the environment or `CF_SECRETS_ENV`. Never paste a key into this file.

Record, from the run output and the cache:

1. Manifest hash (printed as `manifest <hash>`).
2. MP4 sha256 (printed as `mp4 <sha256> <path>`).
3. Duration: `timeline.total_ms` from manifest.json.
4. Integrated loudness: `input_i` from the pass 1 loudnorm JSON.

Gates: the `--final` run must print `ux lint: 0 finding(s)` (every rule, including `caption-safe`, `device-frame`, and ancestor-clipped `clipped-text`); a finding means a fixture screen regressed. The final needs a finished roast loop: render `--draft` first and drive the loop to `stop` (or pass `--no-roast` for an offline check, which skips the gate only when no roast is on record). Do not pass `--allow-ux-findings` or `--allow-roast-findings` here. To exercise the roast gate, render `--draft` first (one paid round, estimate printed, under the run cap) and confirm `roast/round-1.json` and its keyframes exist.

Then delete `.cache/render/` only and run the same command again. Compare:

- the set of `.cache/frames/<frames_key>/` directories: must match;
- the FFmpeg pass 2 argv (rebuild it from the same manifest): must match;
- the MP4 sha256: advisory. If it differs, record that here and file it against the deferred frame byte-identity issue.

## Recorded results

Status: pending.

The first attempt (2026-10-28, real keys present, estimate $0.04) stopped in frame capture of the first scene with `TypeError: window.__cfAdvance is not a function` from `scripts/prototype_capture.rb`. The controlled clock script is registered with `page.evaluateOnNewDocument` and the screen is then loaded by the inline HTML helper, so the clock is not present on the evaluated page. That is a capture pipeline defect outside this skill; once it is fixed, rerun the runbook above and fill in:

| Field | Run 1 | Run 2 |
|---|---|---|
| Manifest hash | pending | pending |
| MP4 sha256 | pending | pending |
| Duration (ms) | pending | pending |
| Integrated loudness (LUFS) | pending | pending |
| Frame keys match | pending | pending |
| Argv match | pending | pending |
