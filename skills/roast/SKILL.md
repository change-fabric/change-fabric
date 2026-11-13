---
name: cf:roast
group: workflow
description: Multi-round roast of a UX, writing, a production architecture, a git diff, or Terraform or AWS infra, optionally through cf rubric lenses, a sub-skill of cf:design. An OpenAI vision model (the critic) reads screenshots plus the earlier rounds and returns a harsh, specific roast as JSON (score out of 10, P0/P1/P2 issues with where, problem, and fix, and a purpose-test verdict per stated outcome); Claude accepts or rebuts each issue, applies the accepted fixes, re-captures, and starts the next round. Stops at a target score (default 9), a round cap (default 4), or a round with no P0 or P1. Each round is logged to a roast/ directory beside the artifact. Paid, so it runs only when invoked by name or loaded by cf:design, cf:walkthrough, or cf:prototype, never auto-applied or chosen on a model guess. Usable alone on any set of screenshots or on a text (email, doc, PR description, post, diff, .tf file, architecture doc).
---

# CF roast

Source: the OpenAI Responses API with image input and Structured Outputs, https://developers.openai.com/api/docs/guides/images-vision and https://developers.openai.com/api/docs/guides/structured-outputs (checked 2026-10-28). The usability lens is cf:usability.

A thin command over `ruby ~/.claude/cf/bin/roast.rb`, which makes one critic call per round. Everything judgment-shaped (accept, rebut, fix) is this session's job, not the script's.

## When

Optional, after screens exist: cf:design may roast a draft's mock screens, cf:prototype and cf:walkthrough may roast the stills before recording motion. cf:walkthrough runs this loop by default on every draft render, before any human sees it: one round per draft over keyframes of the draft MP4 plus the narration transcript and captions, a walkthrough rubric, a stop rule of score 8.5 or more with no P0 or P1, 4 rounds, or its run spend cap (`--roast-max-usd`, across rounds, logged in `roast/spend.json`), and changed-scene-only re-renders between rounds. Its `--final` refuses with no roast on record, an open P0 or P1, or an unfinished loop unless `--allow-roast-findings` is passed. The response, fix, and next-draft loop below is the same. It runs on screenshots or on any text file, including a diff (`git diff > change.diff`), a `.tf` file, or an architecture doc. Never without the user knowing it spends money.

## Inputs

- Screenshots: PNG, JPEG, or WebP, one per screen state. For cf:prototype screens use the stills (`prototype_capture.rb --still`); for a running app, capture in browserless.
- Text, instead of or beside screenshots: `--text <file>` (repeatable). See Text roasts.
- A brief: a short text file (the audience, the goal of the screens, the one task that matters, constraints from DESIGN.md). The critic only knows what the brief and pixels tell it.
- `roast/` beside the artifact (the log directory).

`ruby ~/.claude/cf/bin/roast.rb --brief brief.md --shot a.png --shot b.png [options]`

- `--out-dir <dir>` (default `roast`): round logs land here and prior rounds are read from here.
- `--history <dir>`: read prior rounds from another directory (default: the out dir).
- `--round <n>`: default is the next number after the highest logged round.
- `--max-usd <n>` (default 0.5): the ceiling. A call that would pass it is refused before any request.
- `--transcript <file>`: narration and caption text the critic reads next to the frames; it joins the cache key.
- The review contract, required: the artifact declares what it is. `--kind explainer|promo|demo|email|doc|pr|post|arch|code|infra|fidelity`, `--audience <text>`, and `--purpose <outcome>` (repeatable, the outcomes a viewer must be able to state afterward), or `--storyboard <storyboard.json>` to read its `review` object (`kind`, `audience`, `purpose`). Precedence per key: flags, then the storyboard, then `change_config.design.roast.kind` and `.audience` in CHANGE.md. The script refuses (exit 1, before any call) when audience or purpose resolves empty. The critic runs a purpose test, not a generic first-visit test: per outcome pass, partial, or fail in `purpose_test` (`thirty_second_test` keeps the overall verdict). Score anchors: 3 fails its audience, 5 has a blocking flaw for it, 7 serves it with clear fixes left, 9 ship it. An explainer needs no call to action or install link unless a purpose asks; a promo keeps the what, who, next-step test; a demo must show the thing running. The critic is told frames are sampled keyframes and captions may be sidecar srt or vtt, so pass `--transcript` and it will not report missing captions from keyframes alone.
- `--cache <dir>` (default `.cache`), `--estimate-only`, `--model <name>`, `--effort <level>`. The model resolves through one chain: `--model`, then `CF_ROAST_MODEL`, then the repo config `model`, then the per-kind default (`gpt-6.1-terra` for the text kinds `email`, `doc`, `pr`, `post`, `diff`, `code`, `arch`, `infra`; `gpt-6.1-sol` for screenshots, the walkthrough kinds `explainer`, `promo`, `demo`, and video). Each step accepts the aliases `terra` (`gpt-6.1-terra`) and `sol` (`gpt-6.1-sol`); any other name passes through as a full model ID. Any `--shot` defaults the model to Sol unless `--model`, env or config overrides it. The estimate prices the model that runs; a model with no known price is estimated at Sol rates with a warning line, so it is never underpriced.
- `--effort none|low|medium|high|xhigh|max` (default `medium`) is always sent as `reasoning.effort`. `none` on a Sol model is refused (exit 2). The cache key gains an effort field only when the effort is not `medium`, so rounds cached before this flag existed still hit.

`roast.rb decide --out-dir roast [--target 9] [--cap 4]` prints `roast decision: stop|continue: <reason>` from the latest logged round, so the stop rule is not re-derived by hand.

Settings from CHANGE.md: when the repo's root `CHANGE.md` sets `change_config.design.roast`, its keys fill in for absent flags: `target` and `rounds` for `decide` (`--target`, `--cap`), `max_usd` for the ceiling (`--max-usd`), `model` for the critic (an alias or full ID; `--model` and `CF_ROAST_MODEL` both win over it), `kind` and `audience` as review defaults. A flag given always wins; a key left unset keeps this script's default. `--repo <dir>` names the repo (default the working directory). `roast.rb settings [--repo <dir>]` prints the resolved `auto`, `target`, `rounds`, `max_usd`, and `model`; a loading skill (cf:design, cf:prototype, cf:walkthrough) skips the roast when `auto` is false, the same as `--no-roast`. A malformed block is a named failure (exit 1).

Exit codes: 0 ok, 1 a named failure (ceiling, missing key, HTTP error, invalid reply, missing file, missing audience or purpose, sensitive term), 2 usage, 3 kind ambiguous, 4 enroll a key source.

## Text roasts

`--text <file>` (repeatable) sends text to the critic next to or instead of `--shot` images; give at least one of the two. Text kinds: `email` (is the ask, the deadline, and why it matters to the reader clear; length, tone, what could land badly), `doc`, `pr`, `post`, plus three CLI-only kinds: `arch` (a production architecture: reliability, scalability, maintainability), `code` (a unified diff: correctness risk and smells, `where` is file:line), and `infra` (Terraform or AWS config: change safety, security, cost, reliability). The CLI-only kinds take `--kind` or inference (a diff infers `code`, a `.tf` file `infra`, an `## Architecture` heading `arch`); CHANGE.md `roast.kind` does not accept them yet. Audience and purpose are still required; the score anchors, 8.5 target, and spend cap are unchanged. Each issue's `where` is a quoted phrase or paragraph number (a screen or scene for visuals); older rounds and response files that say `screen` still work.

`/cf:roast --text draft.md --kind email --audience "Finance leads at a mid-size firm" --purpose "Approve the budget by Friday"`

Kind inference: when no flag, storyboard, or CHANGE.md names a kind, roast infers one from cheap cues (a storyboard's narration; a `.eml`, `Subject:`/`To:` headers, or a greeting for email; a test plan or `Closes #n` for pr; hashtags for post; several headings for doc), prints `roast kind: <kind> (inferred, confidence ...)`, and proceeds. `roast.rb infer --text FILE | --storyboard FILE` previews it. Image-only input with no cues stays kind-less. If the cues do not settle on one kind, it exits 3 with `roast: kind is ambiguous: candidates X, Y; pass --kind` and spends nothing. Resolve that with AskUserQuestion (the candidates as options), and ask for a missing audience or purpose the same way, then re-run with the answer as a flag. Under away mode take the top candidate and report the assumption.

Privacy: before any call, the brief, `--text` files, the transcript, and prior rounds (in `--video` mode too) are scanned against `~/.claude/cf/sensitive_terms.txt` (one term per line, case-insensitive, skipped when absent). A match refuses with exit 1 and the count of terms matched, never the term, unless `--allow-sensitive` is passed; do not pass it without the user's say-so.

## Fidelity roasts

`--kind fidelity` with `--pair proto.png=ref.png` (repeatable; a pair implies the kind) compares a prototype still with a still of the production app it extends, for a monorepo design target (spec 0.18.0). Each pair sends the prototype then the reference, and the brief lists the pairing. The critic judges design-system fidelity only: type, spacing and layout, components, color, and the app shell. It ignores data content, copy, and masked regions. Audience and purpose default to the app's own team and "each prototype still reads as a screen of the production app"; flags still win. CLI-only: CHANGE.md `roast.kind` does not accept it. The sensitive-terms scan and the printed estimate run before the call as usual; reference stills come from `prototype_reference.rb` into the ignored `.cache/reference/<target>/` and are never published. In cf:prototype the loop logs to `roast/fidelity/`, stops at score 9 (advisory) or round cap 4, and its stop is the stills sign-off.

`/cf:roast --brief brief.md --pair .cache/stills/analytics/000001.png=.cache/reference/portal/admin-analytics.png --out-dir roast/fidelity`

## Lenses

A lens is the body of a cf rubric skill (for example cf:terraform, cf:aws, cf:refactoring) added to the critic prompt as an extra rubric. `--lens NAME` (repeatable) takes `aws` or `cf:aws`. Ruby routes, a haiku agent culls:

1. Run `ruby ~/.claude/cf/bin/roast.rb infer --text FILE...` and read the `roast lenses suggested:` line, the rubric skills whose paths match the inputs (including the `+++ b/` paths inside a diff). Nothing is applied silently.
2. If candidates exist and the user named no lens, run one Agent (subagent_type general-purpose, model haiku, foreground). Give it the input file paths and each candidate's `~/.claude/skills/cf:NAME/SKILL.md`. Ask for a JSON list of the candidates whose rubric clearly applies to the input, with a one-line reason each. Drop any name it returns that is not in the candidate list.
3. Pass each kept name as `--lens cf:NAME`. A lens the user named always applies, culled or not.
4. Only `group: rubrics` skills are lenses; any other name exits 2. Lenses apply to stills and text roasts, not `--video` (exit 2). Lens bodies join the cache key, the estimate, and the sensitive-term scan.

## Video mode

`roast.rb --video walkthrough.mp4 --brief brief.md [--transcript walkthrough.vtt]` roasts a finished video as a whole. It pairs with the stills roast: stills check each screen up close, video mode checks what only plays in motion. Its model resolves through the same chain as stills (`--model`, `CF_ROAST_MODEL`, repo config, the video default `gpt-6.1-sol`), with `CF_ROAST_VIDEO_MODEL` as a video-only override checked after `--model` and ahead of `CF_ROAST_MODEL`. `--effort` and `--repo` work as for stills. The API takes no video, so ffmpeg samples the MP4 at about 1.5 fps, 1280px wide, and every frame goes in one request, in order, each labelled with its mm:ss time. The narration cues come from the .vtt next to the MP4 unless `--transcript` names another file.

The rubric covers narration against the picture, pacing, abrupt cuts, cursor motion, voice and music balance (inferred from the cues, since the critic cannot hear), whether the story holds for the audience in the brief, and text readability as it plays. The reply is the stills JSON plus a `timestamp` (mm:ss) on every issue.

It reads the same history (stills rounds and earlier video rounds with their responses), prints the estimate first, refuses past `--max-usd` (default 0.5), and caches by model, effort (when not medium), brief, transcript, history, and the MP4 sha256. It writes `roast/round-N.video.json` and `roast/round-N.video.md`, where N defaults to the latest stills round. Respond in `round-N.video.response.json`, same shape as the stills response. A 2-minute video is about 180 frames and roughly $0.40.

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

`OPENAI_API_KEY` from the environment, the env file named by `CF_SECRETS_ENV`, or this project's enrolled source, needed only when a call is made. Exit 4 with a `cf_enroll` line means this project has no key source recorded: enroll it and re-run, see `skills/walkthrough/reference/key-enrollment.md`. Never print or write it. The cache key is a hash of the model, the effort when not medium, round, brief, history, and the screenshot and text digests, so a rerun of identical inputs is a cache hit: no call, no key, $0.00. A changed screenshot or a new response file is a new key and a new paid call.

## Done when

- Every paid round was preceded by a shown estimate and stayed under the ceiling.
- `roast/` holds round-N.json, round-N.md, and round-N.response.json for each round run.
- The report to the user gives the score per round, the stop reason, what was fixed, what was rebutted and why, and any open P0 or P1.
