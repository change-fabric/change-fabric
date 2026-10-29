---
name: cf:roast
group: workflow
description: Multi-round roast of a UX, a sub-skill of cf:design. An OpenAI vision model (the critic) reads screenshots plus the earlier rounds and returns a harsh, specific roast as JSON (score out of 10, P0/P1/P2 issues with screen, problem, and fix, and a 30-second-test verdict); Claude accepts or rebuts each issue, applies the accepted fixes, re-captures, and starts the next round. Stops at a target score (default 9), a round cap (default 4), or a round with no P0 or P1. Each round is logged to a roast/ directory beside the artifact. Paid, so it runs only when invoked by name or loaded by cf:design, cf:walkthrough, or cf:prototype, never auto-applied or chosen on a model guess. Usable alone on any set of screenshots.
---

# CF roast

Source: the OpenAI Responses API with image input and Structured Outputs, https://developers.openai.com/api/docs/guides/images-vision and https://developers.openai.com/api/docs/guides/structured-outputs (checked 2026-10-28). The usability lens is cf:usability.

A thin command over `ruby ~/.claude/cf/bin/roast.rb`, which makes one critic call per round. Everything judgment-shaped (accept, rebut, fix) is this session's job, not the script's.

## When

Optional, after screens exist: cf:design may roast a draft's mock screens, cf:prototype and cf:walkthrough may roast the stills before recording motion. cf:walkthrough runs this loop by default on every draft render, before any human sees it: one round per draft over keyframes of the draft MP4 plus the narration transcript and captions, a walkthrough rubric, a stop rule of score 8.5 or more with no P0 or P1, 4 rounds, or its run spend cap (`--roast-max-usd`, across rounds, logged in `roast/spend.json`), and changed-scene-only re-renders between rounds. Its `--final` refuses with no roast on record, an open P0 or P1, or an unfinished loop unless `--allow-roast-findings` is passed. The response, fix, and next-draft loop below is the same. Never for a repo with no visual artifact, and never without the user knowing it spends money.

## Inputs

- Screenshots: PNG, JPEG, or WebP, one per screen state. For cf:prototype screens use the stills (`prototype_capture.rb --still`); for a running app, capture in browserless.
- A brief: a short text file (the audience, the goal of the screens, the one task that matters, constraints from DESIGN.md). The critic only knows what the brief and pixels tell it.
- `roast/` beside the artifact (the log directory).

`ruby ~/.claude/cf/bin/roast.rb --brief brief.md --shot a.png --shot b.png [options]`

- `--out-dir <dir>` (default `roast`): round logs land here and prior rounds are read from here.
- `--history <dir>`: read prior rounds from another directory (default: the out dir).
- `--round <n>`: default is the next number after the highest logged round.
- `--max-usd <n>` (default 0.5): the ceiling. A call that would pass it is refused before any request.
- `--transcript <file>`: narration and caption text the critic reads next to the frames; it joins the cache key.
- `--cache <dir>` (default `.cache`), `--estimate-only`, `--model <name>`. `CF_ROAST_MODEL` overrides the model (default `gpt-6.1-sol`, a vision-capable model with strict JSON schema output; set it to another when wanted).

`roast.rb decide --out-dir roast [--target 9] [--cap 4]` prints `roast decision: stop|continue: <reason>` from the latest logged round, so the stop rule is not re-derived by hand.

Settings from CHANGE.md: when the repo's root `CHANGE.md` sets `change_config.design.roast`, its keys fill in for absent flags: `target` and `rounds` for `decide` (`--target`, `--cap`), `max_usd` for the ceiling (`--max-usd`), `model` for the critic (`--model`, else `CF_ROAST_MODEL`). A flag given always wins; a key left unset keeps this script's default. `--repo <dir>` names the repo (default the working directory). `roast.rb settings [--repo <dir>]` prints the resolved `auto`, `target`, `rounds`, `max_usd`, and `model`; a loading skill (cf:design, cf:prototype, cf:walkthrough) skips the roast when `auto` is false, the same as `--no-roast`. A malformed block is a named failure (exit 1).

Exit codes: 0 ok, 1 a named failure (ceiling, missing key, HTTP error, invalid reply, missing file), 2 usage.

## The round

1. Run `roast.rb` with `--estimate-only` for round 1 and show the user the `roast estimate:` line. The estimate is a rough token-based planning figure, not a quote. Each later round costs more as history grows.
2. Run it for real. It writes `roast/round-N.json` (the critic's JSON) and `roast/round-N.md` (a readable copy), and prints the score.
3. Respond to every issue, in your own words, never by rubber-stamping. Write `roast/round-N.response.json`:

```json
{ "responses": [
  { "screen": "home", "problem": "<the critic's problem, short>", "verdict": "accept", "change": "<what you will change>" },
  { "screen": "pricing", "problem": "<...>", "verdict": "rebut", "reason": "<why the critic is wrong, tied to the brief or DESIGN.md>" } ] }
```

   Accept what is right even when it stings. Rebut only with a reason grounded in the brief, DESIGN.md, or the user's stated constraints; a rebuttal with no such ground is an accept. The next round's critic sees these and may hold the line.
4. Apply the accepted fixes to the artifact (screens, DESIGN.md, tokens), keeping to the tokens and the cf:usability, cf:fractal, and cf:prototyping rules (load cf:fractal by name before applying a layout or spacing fix, so a fix reuses an existing module instead of inventing one). Do not touch what the roast did not raise.
5. Re-capture the screenshots, then run `roast.rb decide`. On `continue`, go to step 2 for the next round; on `stop`, finish.

## Stop rule

First match on the latest round wins: score at or above the target (default 9), no P0 or P1 issue, or the round cap (default 4). The user may override target and cap. Past the cap, report the open issues instead of running another paid round.

## Judgment the user keeps

Contested calls (a rebuttal the critic keeps repeating, a fix that conflicts with DESIGN.md) are escalated to the user with AskUserQuestion, not settled silently by either model.

## Keys and cost

`OPENAI_API_KEY` from the environment or the env file named by `CF_SECRETS_ENV`, needed only when a call is made. Never print or write it. The cache key is a hash of the model, round, brief, history, and the screenshot digests, so a rerun of identical inputs is a cache hit: no call, no key, $0.00. A changed screenshot or a new response file is a new key and a new paid call.

## Done when

- Every paid round was preceded by a shown estimate and stayed under the ceiling.
- `roast/` holds round-N.json, round-N.md, and round-N.response.json for each round run.
- The report to the user gives the score per round, the stop reason, what was fixed, what was rebutted and why, and any open P0 or P1.
