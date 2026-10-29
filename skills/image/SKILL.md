---
name: cf:image
group: workflow
description: Image command. Generates, or edits, a still with the OpenAI Images API (gpt-image-2) from a prompt or prompt file, with optional reference images for consistency across shots and an edit image with a mask, cached by content key, with a cost estimate printed before any paid call and an explicit ceiling. Never for UI screenshots. Paid, so it runs only when invoked by name or loaded by cf:prototype or cf:walkthrough, never auto-applied or chosen on a model guess. Usable alone, outside any walkthrough.
---

# CF image

Source: the OpenAI image generation guide https://developers.openai.com/api/docs/guides/image-generation (checked 2026-10-28).

A thin command over `ruby ~/.claude/cf/bin/image.rb`. It has no provider code of its own: generation, the cache, and the edits multipart live in `prototype_imagegen.rb`, shared with cf:prototype and cf:design.

## Never for UI

Never use this for UI screenshots, screens, forms, charts, or anything with text the viewer must read. Screens are HTML/CSS in cf:prototype. Use cf:image only for in-screen imagery (avatars, product photos, hero art) and B-roll source stills.

## Prompt guidance

- Write candid, documentary prompts: a real place, ordinary light, an unposed moment, a named lens or film look only if it helps. Describe what is in the frame, not that it is "stunning".
- Avoid the generic AI-look defaults in `skills/design/reference/banned-defaults.md` (a dated list, reviewed whenever touched): no purple gradients, glass, floating 3D blobs, sparkles, or neon on near-black unless DESIGN.md chose one.
- Ask for no text, logos, or watermarks in the image; they render badly.
- For consistency across shots, pass the earlier winner with `--ref` and restate the fixed details (subject, wardrobe, palette) in every prompt.

## Inputs

`ruby ~/.claude/cf/bin/image.rb "<prompt>" | --prompt-file <file> [options]`

- `--size <WxH>` (default `1024x1024`; `1536x1024` and `1024x1536` are the documented landscape and portrait sizes).
- `--quality low|medium|high` (default `medium`; use `high` for finals).
- `--ref <png>`: a reference image, repeatable. Uses the edits endpoint.
- `--edit <png>` with an optional `--mask <png>`: change an existing image. The mask needs an alpha channel and the edit image's size; it applies to the first image only, so the edit image is always sent first.
- `--out <path>`: copy the result there (otherwise the cache path is printed).
- `--max-usd <n>` (default 1): the cost ceiling. A request that would pass it is refused before any call.
- `--cache <dir>` (default `.cache`), `--estimate-only`. `CF_IMAGE_MODEL` overrides the model.

Exit codes: 0 ok, 1 a named failure (ceiling, missing key, HTTP error, missing file), 2 usage.

## Steps

1. The command prints `image estimate: ...` before any call. Show it to the user before a paid run (`--estimate-only` makes no call).
2. Run it. The `image:` line is the output path.
3. The cache key is a hash of model, prompt, size, quality, and the ref, edit, and mask file digests. A rerun is a cache hit: no call, no key, $0.00. cf:prototype and the walkthrough render share the cache, so an image made here is reused by them.
4. Edit the prompt instead of rerolling. Each run is one paid call, so a retry cap is the caller's job (cf:prototype caps attempts per screen).

## Keys

`OPENAI_API_KEY` from the environment or the env file named by `CF_SECRETS_ENV`, needed only when a call is made. Never print or write it.

## Done when

- The estimate was shown before any paid call.
- The output path is reported, and a failed call is reported with its HTTP status and no key.
