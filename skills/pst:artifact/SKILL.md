---
name: pst:artifact
description: Turn a plan into a bespoke interactive artifact in the Astro studio - click-anywhere comments, one-command publish.
argument-hint: '[<plan.md>] [--exec] [--theme <name>] [--ttl <7|30d|never>] [--title "..."] | <id|url> (iterate) | --feedback <id> | --publish <id|url> [--ttl …] | --destroy <id> | --list'
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# pst:artifact - the planning artifacts studio

Turn a plan - recommended next steps drafted in the terminal, or a markdown plan
file - into a **bespoke, interactive web artifact** rendered by a local Astro
"studio" app. Think a private, self-hosted Claude Artifacts: each plan is its own
page, composed (not templated) from a rich component kit, given its own art
direction, reviewable with **click-anywhere comments**, and publishable to a
no-index subdomain with one command.

This replaces the old `/plan-io` single-file HTML builder. Generate immediately;
no interview.

## Quick reference

```bash
# Pivot the plan Claude just produced in this conversation (most common)
/pst:artifact

# Executive summary of the current session: what shipped + prescriptive next steps
/pst:artifact --exec

# Render a markdown plan file, pick an art direction
/pst:artifact ./docs/migration-plan.md --theme technical --title "Q3 Platform Migration"

# Revise an existing artifact from the comments you left in the browser
/pst:artifact --feedback k3f9q2

# Publish to your subdomain (default 7-day TTL; needs plans.config.json + terraform)
/pst:artifact --publish k3f9q2
/pst:artifact --publish k3f9q2 --ttl 30d        # 30 days
/pst:artifact --publish k3f9q2 --ttl never      # keep forever

# Iterate on a published artifact from ANY session - pass its id or URL.
# Same id/URL is preserved; it's updated in place.
/pst:artifact k3f9q2 "make the hero calmer and tighten the steps"
/pst:artifact https://artifacts.pstaylor.net/p/k3f9q2/whatever "fix the third stat"

# Destroy one now (the reaper also auto-destroys at TTL)
/pst:artifact --destroy k3f9q2

# List existing artifacts
/pst:artifact --list
```

**Defaults when bare:** source = the most recent plan / recommended next steps in
the current conversation; theme auto-chosen to fit the topic; opens `astro dev`
in the browser at the new artifact. Publishing is opt-in and only lights up once
`plans.config.json` exists. **Published artifacts self-destruct after 7 days by
default** - pass `--ttl` to change it.

## Resolve the skill directory first

The command is a symlink into the skills repo. Resolve its real location, then
work relative to it:

```bash
SKILL_DIR="$(dirname "$(readlink -f "$HOME/.claude/commands/pst:artifact.md" 2>/dev/null || echo "$HOME/.claude/commands/pst:artifact.md")")"
STUDIO="$SKILL_DIR/studio"
PLANS="$STUDIO/src/content/plans"
```

If `readlink -f` is unavailable (older macOS), fall back to `python3 -c "import os,sys;print(os.path.dirname(os.path.realpath(sys.argv[1])))" "$HOME/.claude/commands/pst:artifact.md"`.

## The studio (read it; don't reinvent it)

- **Component kit: `studio/src/components/kit/`** - the block vocabulary you
  author with (`Hero, Section, Stats/Stat, Steps/Step, Features/Feature,
Card/CardGrid, Compare, Ledger, Mockup, Diagram, Callout, Pill, Link, Icon`).
  Import from `@kit`. **Re-read these props each run; don't guess.**
- **Worked example + reference: `studio/src/content/plans/welcome.mdx`** - a real
  artifact using most of the kit. The best template is this example, not a blank.
- **Art direction: `studio/src/lib/theme.ts`** - 5 themes (`editorial`,
  `technical`, `minimal`, `vivid`, `classic`). Pick one per plan; optionally
  override `accent`.
- **Schema: `studio/src/content.config.ts`** - the MDX frontmatter contract.
- Layout, comments, routing, fonts are handled for you - don't touch them.

## Steps

### 1. Parse arguments

- `--feedback <id>` → jump to **Revise** flow.
- `--publish <id|url>` → jump to **Publish** flow.
- `--destroy <id|url>` → jump to **Destroy** flow.
- `--list` → `ls "$PLANS"` and print each id + title; stop.
- **An existing id or a published URL as the first token** (matches a 4–8 char
  id, or contains `/p/<id>/`) → **Iterate-in-place** flow: extract the id, edit
  that artifact, re-publish under the **same id**. Any extra prose is the change
  request.
- `<*.md>` positional → read that file as the source plan (new artifact).
- No positional → use the **most recent plan / recommended next steps from the
  current conversation** as the source. Set `sourcePath` to a short note.
- `--exec` → executive-summary preset: synthesize from the conversation an
  outcome-led briefing (a `Hero`, a `Stats` row of what shipped, prescriptive
  `Steps`, optional decisions/risks `Card`s). Crisp, stakeholder-facing.
- `--theme <name>` to force art direction; `--title "..."` to override; `--no-open`
  to skip the browser.
- `--ttl <value>` → time-to-live for a publish. The value is fuzzy and you
  interpret it: a bare number means **days** (`7`, `30`); `30d`/`2w`/`"two weeks"`
  → that many days; `never`/`forever`/`∞`/`keep` → never expires. Normalize to
  either an integer (days) or the literal `never`, then pass to `publish.py`.
  **Default is 7 days** when omitted on a first publish.

### 2. Pick an id + slug

```bash
read -r ID SLUG < <(python3 "$SKILL_DIR/scripts/plan_id.py" --plans-dir "$PLANS" --slug "<the title>")
```

The `ID` is the stable, collision-checked short id that lives in the URL forever.
The `SLUG` is cosmetic. The MDX **filename is the id**: `$PLANS/$ID.mdx`.

### 3. Author the artifact (the creative work)

Re-read the kit, then **Write `$PLANS/$ID.mdx`** - frontmatter per the schema
(`title`, `permalink: <SLUG>`, `eyebrow`, `subtitle`, `summary`, `theme`,
optional `accent`, `tags`, `status`, `sourcePath`, `createdAt`, `updatedAt`),
then a body composed from `@kit` blocks. Map the source onto blocks:

- **Outcome / value** → `Hero` (lead with the result), `Stats` colored cards.
- **Phased steps** → `Steps` with priority/owner/effort pills.
- **Options / tradeoffs** → a sortable `Compare` table.
- **Line items / inventory / scope** → grouped `Ledger`.
- **Architecture / flow** → hand-authored inline-SVG inside `Diagram`.
- **Proposed UI** → `Mockup` rendering real theme markup (a live frame, not an image).
- **Goals / capabilities** → `Features` icon grid.
- Put a `data-anchor` on meaningful units (most kit blocks accept `anchor`) so
  they're commentable.
- **External links:** emit a real `<Link href>` only for canonical URLs you
  actually know. **Never fabricate a URL.**

### 4. Run the studio

```bash
cd "$STUDIO" && [ -d node_modules ] || npm install
npm run dev   # background it; it prints a localhost URL
```

Then open `http://localhost:4321/p/$ID/$SLUG` (unless `--no-open`). Report the id.

### 5. Revise flow (`--feedback <id>`)

Read `$STUDIO/feedback/<id>.json` (threads the user dropped in the browser; each
has `anchor`, `section`, `selector`, `snippet`, `comment`). Apply each comment by
editing `$PLANS/<id>.mdx`, then tell the user to refresh. Keep the id stable.

### 6. Publish flow (`--publish <id|url>`)

```bash
# --ttl is optional: integer days or "never". Omit to keep the artifact's
# current expiry (or default to 7 days on a first publish).
python3 "$SKILL_DIR/scripts/publish.py" --skill-dir "$SKILL_DIR" --id "<id>" [--ttl <days|never>]
```

Requires `plans.config.json` (copy from `plans.config.example.json`) and a
one-time `terraform apply` in `terraform/`. The script runs the a11y contrast
gate, builds, uploads **just this artifact** (so other artifacts' expiry tags are
untouched), stashes the MDX source privately to S3 for later iteration, tags the
page with its expiry, invalidates CloudFront, and prints the URL + expiry. The
URL is `https://<domain>/p/<id>/<slug>` - the id is canonical; the slug cosmetic.

**TTL / self-destruct.** Every published artifact carries an `expires-at` tag. A
daily reaper (Terraform-provisioned, on by default) **deletes expired artifacts
outright from S3** and invalidates them. Default lifetime is **7 days**; `--ttl
never` opts out. Re-publishing without `--ttl` preserves the current expiry, so
iterating doesn't silently shorten or extend a shared link's life.

### 6b. Iterate-in-place flow (id or URL, from any session)

The point: workshop a published artifact over many sessions/machines **without
changing its id or URL**. Given an id or a `…/p/<id>/…` URL:

```bash
ID="<extracted id>"
SRC="$PLANS/$ID.mdx"
# If this clone doesn't have the source, pull the copy publish.py stashed in S3.
if [ ! -f "$SRC" ]; then
  BUCKET=$(python3 -c "import json,sys;print(json.load(open('$SKILL_DIR/plans.config.json'))['domain'])")
  PROFILE=$(python3 -c "import json,sys;print(json.load(open('$SKILL_DIR/plans.config.json'))['awsProfile'])")
  aws s3 cp "s3://$BUCKET/p/$ID/_source.mdx" "$SRC" --profile "$PROFILE"
fi
```

Then **edit `$SRC` in place** to apply the requested change, and re-publish with
the **same id** (Step 6, no `--ttl` unless asked → expiry preserved). The id,
URL, and lifetime stay stable; only the content changes. If the source can't be
recovered (never published, or a different bucket), say so rather than guessing.

### 6c. Destroy flow (`--destroy <id|url>`)

```bash
python3 "$SKILL_DIR/scripts/publish.py" --skill-dir "$SKILL_DIR" --id "<id>" --destroy
```

Immediately removes the artifact's `/p/<id>/` prefix from S3 and invalidates it -
the same thing the reaper does at TTL, on demand.

### 7. Report back

Print: the artifact id and its local URL; the theme/art direction chosen; the
blocks used; any assumptions made when the plan was sparse; and the one-liner -
_"In the page: click Comment, drop pins anywhere, then re-run `/pst:artifact
--feedback <id>` to apply."_

## Authoring rules - make it executive-friendly, never slop

**Counter-inspiration (what NOT to do):** a dark background with fifteen
visually-identical list rows, no hierarchy, no imagery - a wall of text. That is
the exact failure mode this tool exists to kill.

**North star:** warm, light, editorial; generous negative space; a strong hero;
scannable colored stats; varied rhythm; a real diagram or mockup where it helps;
a clean footer. Production-ready, not tossed-up.

- **Lead with the outcome**, not a title or a preamble.
- **Vary the composition.** If two adjacent sections use the same block, you're
  drifting toward a wall of text - switch it up (alternate `Section` tint, mix
  `Stats`/`Compare`/`Ledger`/`Diagram`).
- **Bespoke, not boilerplate.** Choose art direction (theme + accent), section
  order, and diagrams that fit _this_ prompt. Two different plans should not look
  like the same template.
- **Light themes only** - never emit a dark background.
- **Show, don't tell** - prefer a `Diagram`/`Mockup`/`Stats` over another paragraph.
- **Compose the kit; don't freehand HTML/CSS.** Re-read the kit props instead of guessing.
- **Contrast is enforced.** Theme/kit colors are gated by `studio/src/a11y.test.ts`
  (WCAG AA), which `publish.py` runs before every build. If you add a color or a
  new on-color combination, add it to that test; never hand-tune colors that
  dodge it. For a deeper DOM-level audit of a built page, run `/REDACTED:accessibility`
  (axe via Playwright) against the dev server.

## Constraints

- **Generate immediately** - no interview, even for thin plans. Surface
  assumptions in the report-back.
- **Filename = stable id.** Never rename an artifact's file or change its id once
  shared - the URL depends on it. The slug (`permalink`) is the only mutable part.
- **Never modify the studio internals** (layout, comments, routing, kit) per
  invocation - author content in `$PLANS/*.mdx` only. Improvements to the kit are
  a separate, deliberate change.
- **Publishing is opt-in.** No `plans.config.json` → local-only; don't try to
  publish. Artifacts are **no-index/no-follow by default**.
- **Never commit secrets or `plans.config.json`** (git-ignored).

## Error handling

| Condition                                                 | Action                                              |
| --------------------------------------------------------- | --------------------------------------------------- |
| No plan in conversation and no file arg                   | Ask for a plan file or the plan text first          |
| Source `.md` path missing                                 | Fail with the resolved path; don't fuzzy-match      |
| `node`/`npm` missing                                      | Tell the user to install Node 20+                   |
| `--feedback <id>` with no feedback file                   | Say there are no saved comments for that id         |
| `--publish` without `plans.config.json`                   | Point to `plans.config.example.json` + `terraform/` |
| `--publish` but no CloudFront distribution for the domain | Tell the user to `terraform apply` first            |
