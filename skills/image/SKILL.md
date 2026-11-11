---
name: cf:image
group: workflow
description: Image command. Generates, or edits, a still with the OpenAI Images API (gpt-image-2.6-sunburst) from a prompt or prompt file, with optional reference images for consistency across shots and an edit image with a mask, cached by content key, with a cost estimate printed before any paid call and an explicit ceiling. Three text modes, none, short (the model draws a few quoted words), or heavy (a textless plate with HTML copy overlaid per size from a JSON spec). Never for UI screenshots. Paid, so it runs only when invoked by name or loaded by cf:prototype or cf:walkthrough, never auto-applied or chosen on a model guess. Usable alone, outside any walkthrough.
---

# CF image

Source: the OpenAI image generation guide https://developers.openai.com/api/docs/guides/image-generation, the model page https://developers.openai.com/api/docs/models/gpt-image-2.6-sunburst, and the pricing page https://developers.openai.com/api/docs/pricing (checked 2026-11-11).

The default model is `gpt-image-2.6-sunburst`; `CF_IMAGE_MODEL` still overrides it. OpenAI shuts `gpt-image-2` down on February 10, 2027: if you pinned `CF_IMAGE_MODEL=gpt-image-2`, unset it or move to the new default. Until then the command prints a one-time warning and carries on. An unknown model is estimated at the highest known per-image price for its quality, so an estimate never under-prices.

A thin command over `ruby ~/.claude/cf/bin/image.rb`. It has no provider code of its own: generation, the cache, and the edits multipart live in `prototype_imagegen.rb`, shared with cf:prototype and cf:design.

## Text in images

Never use this for UI screenshots, screens, forms, or charts. Real app screens are HTML/CSS in cf:prototype. Text in marketing art (banners, posters, hero copy) is handled by one of three modes.

- `none`: no quoted words in the prompt. The prompt asks for no text, logos, or watermarks, as before.
- `short`: one quoted run of up to 4 words and 25 characters, such as `poster saying "Sale"`. gpt-image-2.6-sunburst draws that exact text, large and centered. Check the spelling in the result, and use the overlay for brand-critical copy.
- `heavy`: a longer quoted run, two or more runs, or any `--spec`. gpt-image-2.6-sunburst makes a textless plate per aspect family (landscape 1536x1024, portrait 1024x1536, the second using the first as a reference) with the copy zone kept calm, then real text is laid over each output size with HTML in the pinned browserless container. Heavy needs `--spec copy.json` and Docker.

`--mode none|short|heavy` always overrides the choice. Banner words without quotes (banner, headline, CTA, hero) only print a warning.

The spec carries the copy, the output sizes with a copy zone each (fractions of the frame), and an optional focal point for cropping:

```json
{
  "copy": { "headline": "Ship release gates you can trust", "cta": "Start free" },
  "sizes": [
    { "name": "desktop", "width": 1920, "height": 600,
      "zone": { "x": 0.05, "y": 0.15, "w": 0.45, "h": 0.7 } }
  ],
  "focal": { "x": 0.7, "y": 0.45 }
}
```

Fonts and colors come from the repo `tokens.css` when present, otherwise system fonts. Copy that overflows its zone exits 1 naming the size: shorten the copy or widen the zone. If the model still draws stray text into a plate, regenerate or fix it with an edit mask. The estimate is low for 1536-wide plates.

## Prompt guidance

- Write candid, documentary prompts: a real place, ordinary light, an unposed moment, a named lens or film look only if it helps. Describe what is in the frame, not that it is "stunning".
- Avoid the generic AI-look defaults in `skills/design/reference/banned-defaults.md` (a dated list, reviewed whenever touched): no purple gradients, glass, floating 3D blobs, sparkles, or neon on near-black unless DESIGN.md chose one.
- Put words in the image only through the text modes above; unrequested text renders badly.
- For consistency across shots, pass the earlier winner with `--ref` and restate the fixed details (subject, wardrobe, palette) in every prompt.

## Inputs

`ruby ~/.claude/cf/bin/image.rb "<prompt>" | --prompt-file <file> [options]`

- `--size <WxH>` (default `1024x1024`; `1536x1024` and `1024x1536` are the documented landscape and portrait sizes).
- `--quality low|medium|high` (default `medium`; use `high` for finals).
- `--ref <png>`: a reference image, repeatable. Uses the edits endpoint.
- `--edit <png>` with an optional `--mask <png>`: change an existing image. The mask needs an alpha channel and the edit image's size; it applies to the first image only, so the edit image is always sent first.
- `--out <path>`: copy the result there (otherwise the cache path is printed).
- `--max-usd <n>` (default 1): the cost ceiling. A request that would pass it is refused before any call.
- `--mode none|short|heavy`, `--spec <copy.json>`: see Text in images.
- `--cache <dir>` (default `.cache`), `--estimate-only`. `CF_IMAGE_MODEL` overrides the model.

Exit codes: 0 ok, 1 a named failure (ceiling, missing key from a recorded source, HTTP error, missing file, copy overflow), 2 usage or a malformed spec, 3 Docker unavailable (heavy only), 4 enroll a key source.

## Steps

1. The command prints `image estimate: ...` before any call. Show it to the user before a paid run (`--estimate-only` makes no call).
2. Run it. The `image:` line is the output path.
3. The cache key is a hash of model, prompt, size, quality, and the ref, edit, and mask file digests. A rerun is a cache hit: no call, no key, $0.00. cf:prototype and the walkthrough render share the cache, so an image made here is reused by them.
4. Edit the prompt instead of rerolling. Each run is one paid call, so a retry cap is the caller's job (cf:prototype caps attempts per screen).

## Keys

`OPENAI_API_KEY` from the environment, the env file named by `CF_SECRETS_ENV`, or this project's enrolled source, needed only when a call is made. Exit 4 with a `cf_enroll` line means this project has no key source recorded: enroll it and re-run, see `skills/walkthrough/reference/key-enrollment.md`. Never print or write it.

## Done when

- The estimate was shown before any paid call.
- The output path is reported, and a failed call is reported with its HTTP status and no key.
