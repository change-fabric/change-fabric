---
name: pst:demo
description: Generate a reusable demo/QA runbook skill from the current feature branch
argument-hint: "[--update | --dry-run]"
allowed-tools: Bash, Read, Write, Grep, Glob, AskUserQuestion
---

# Demo Skill Generator

Analyze the current feature branch and generate a 5-minute demo runbook saved as a skill in the target repository. The generated skill serves triple duty: pre-merge QA, PR walkthrough for engineers, and stakeholder demo via Loom. One script, one video, all audiences.

**Opinionated defaults:**

- Target runtime: **5 minutes maximum**. If the feature needs more, split into multiple demos.
- Format: **military talking paper** -- skeleton outline of what to do and what to emphasize, not a script of words to say.
- Audience: **dual** -- the same walkthrough works for technical PR review and non-technical stakeholder updates.
- Delivery model: **briefing then walkthrough** -- starts with an off-camera executive summary to get your head right, then steps through the app one at a time.

---

## Input

<arguments> #$ARGUMENTS </arguments>

**Parse arguments:**

- `--update` - force update mode even if no existing demo skill is detected
- `--dry-run` - print the generated skill to the terminal without writing any files
- No arguments - detect create vs update automatically, write the skill file

---

## Phase 1 -- Context Gathering

Collect git and project context silently (no user interaction).

```bash
BRANCH=$(git branch --show-current 2>/dev/null)
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
```

**Guards -- stop if any are true:**

| Condition                              | Message                              |
| -------------------------------------- | ------------------------------------ |
| Not a git repo                         | "Not a git repo."                    |
| On default branch with 0 commits ahead | "No feature branch changes to demo." |
| No changed files on branch             | "No changes found on this branch."   |

**Gather:**

```bash
MERGE_BASE=$(git merge-base "origin/$DEFAULT_BRANCH" HEAD 2>/dev/null || git merge-base "$DEFAULT_BRANCH" HEAD)
CHANGED_FILES=$(git diff --name-only "$MERGE_BASE"...HEAD 2>/dev/null)
COMMIT_LOG=$(git log --oneline "$MERGE_BASE"...HEAD 2>/dev/null)
DIFF_STAT=$(git diff --stat "$MERGE_BASE"...HEAD 2>/dev/null)
```

**PR context** (non-fatal if `gh` unavailable or no PR exists):

```bash
PR_JSON=$(gh pr view --json title,body,number,url 2>/dev/null || echo '{}')
```

Extract `PR_TITLE`, `PR_BODY`, `PR_NUMBER`, `PR_URL` from `PR_JSON`. If empty, these remain unset.

**Project context** (read silently, skip missing files):

- `package.json` -- detect framework, dev command (`scripts.dev`), seed command, test command
- `README.md` -- project description
- `CLAUDE.md` / `.claude/CLAUDE.md` -- project conventions
- `.env.example` -- required environment variables

---

## Phase 2 -- App ID Resolution

Determine the short app identifier for the demo skill namespace.

**Step 1:** Check for existing demo skills:

```bash
EXISTING_DEMOS=$(ls -d .agents/skills/*:demo:* 2>/dev/null || true)
```

If found, extract the app ID (everything before the first `:demo:`). Use that. Skip to Phase 3.

**Step 2:** Check for any namespaced skills in `.agents/skills/`:

```bash
EXISTING_SKILLS=$(ls -d .agents/skills/*:* 2>/dev/null || true)
```

If found, extract the prefix before the first `:`. Use that. Skip to Phase 3.

**Step 3:** Check alternate skill directories (`.claude/skills/`, `.claude/commands/`):

```bash
ALT_SKILLS=$(ls -d .claude/skills/*:* 2>/dev/null || ls -d .claude/commands/*:* 2>/dev/null || true)
```

If found, extract prefix. Skip to Phase 3.

**Step 4:** If no existing skills provide a namespace, ask the user:

Use **AskUserQuestion**: "This repo has no existing demo skills. What short app identifier should I use? (e.g., 'gg' for great-grants, 'sa' for REDACTED-agents)"

Store result as `APP_ID`.

---

## Phase 3 -- Feature Name Resolution

Derive a proposed feature name.

**Priority order:**

1. **Branch name:** strip prefixes (`feature/`, `feat/`, `fix/`, `chore/`, `bugfix/`, `hotfix/`), convert slashes and underscores to hyphens, lowercase, truncate to 30 chars
2. **PR title:** if branch name is generic (e.g., `dev`, `patch-1`), extract key nouns from PR title, kebab-case them
3. **First commit subject:** last resort, kebab-case the first commit message subject

Compute the proposed name and present via **AskUserQuestion**:

> "I'd name this demo skill `{APP_ID}:demo:{proposed_name}`. Good, or type an override:"

If the user provides an override, use it. If they confirm, use the proposal.

Store as `FEATURE_NAME`.

Compute paths:

```
SKILL_DIR=".agents/skills/${APP_ID}:demo:${FEATURE_NAME}"
SKILL_PATH="${SKILL_DIR}/SKILL.md"
```

---

## Phase 4 -- Create vs Update

**If `$SKILL_PATH` exists AND `--update` flag is set:** enter update mode silently.

**If `$SKILL_PATH` exists AND no `--update` flag:** use **AskUserQuestion**: "A demo skill already exists at `$SKILL_PATH`. Update it with the latest branch changes?"

- Yes: enter update mode
- No: stop

**If `$SKILL_PATH` does not exist:** enter create mode.

**Update mode behavior:** Read the existing SKILL.md content. In Phase 6, merge new information from the updated diff while preserving manually-edited sections.

If `.agents/skills/` directory does not exist, note it will be created in Phase 7.

---

## Phase 5 -- Content Synthesis

This is the core analysis phase. Read the full diff and categorize changes to build the demo content.

### 5A. Categorize Changed Files

Sort `CHANGED_FILES` into buckets:

| Category       | Patterns                                                     |
| -------------- | ------------------------------------------------------------ |
| Routes / Pages | `app/**/page.{tsx,jsx,ts,js}`, `pages/**`, `src/routes/**`   |
| Components     | `components/**/*.{tsx,jsx}`, `src/**/*.{tsx,jsx}` (non-page) |
| API Endpoints  | `app/api/**`, `pages/api/**`, `src/api/**`, `routes/**`      |
| Database       | `migrations/**`, `prisma/**`, `drizzle/**`, `schema.*`       |
| Config         | `*.config.*`, `.env*`, `package.json`                        |
| Tests          | `**/*.test.*`, `**/*.spec.*`, `__tests__/**`                 |
| Styles         | `**/*.css`, `**/*.scss`, `tailwind.*`                        |

### 5B. Extract Demo-Relevant Details

Read the actual diff content for files in the Routes/Pages and Components categories. Extract:

- **New URLs/routes** from file paths and route definitions
- **New UI elements** visible to a user (buttons, forms, modals, navigation items, page titles)
- **New API endpoints** from route handler files
- **New environment variables** from `.env.example` or `.env` diffs
- **User-facing text** (headings, labels, button text, toast messages)
- **Auth requirements** (which user role or state is needed to see the feature)

### 5C. Build Demo Data

From the analysis, construct:

- `EXECUTIVE_SUMMARY`: A concise briefing (5-8 bullet points) covering: what changed and why, who cares about it, what the happy path looks like end-to-end, what to emphasize when narrating. This is read off-camera before recording to get your head in the right space.
- `FEATURE_SUMMARY`: 2-3 sentences describing what the feature does. Source from PR body first, then synthesize from commits and diff.
- `PREREQUISITES`: ordered list of setup steps. Always include the dev server command. Add seed data, env vars, and auth state as detected.
- `DEMO_STEPS`: 4-8 concrete steps. Each step has:
  - A short title
  - A URL or navigation instruction
  - A specific action (click, type, submit, wait)
  - What to emphasize -- the talking point, not the words (e.g., "Emphasize: real-time validation, no page reload")
  - An expected visible outcome for QA verification
- `TALKING_POINTS`: per-step notes on what matters to technical vs non-technical viewers
- `GOTCHAS`: anything a demo-er might trip on (loading states, required seed data, timing issues, known bugs on the branch)

**5-minute budget:** Count the steps. If more than 8, combine or cut. A good demo shows the happy path and one meaningful edge case, not exhaustive coverage. Estimate ~30-45 seconds per step.

**If in update mode:** compare the new analysis against the existing skill content. Add new steps for new functionality, update steps where behavior changed, preserve steps that still apply unchanged.

---

## Phase 6 -- Skill Generation

Generate the SKILL.md content using the data from Phase 5.

### Generated Skill Template

The generated skill has two modes: a **Briefing** section to read before recording, and a **Walkthrough** section that is stepped through interactively one step at a time during the demo.

```markdown
---
name: {APP_ID}:demo:{FEATURE_NAME}
description: Demo walkthrough for {FEATURE_SUMMARY_ONE_LINE}
allowed-tools: AskUserQuestion
---

# Demo: {Feature Title}

{FEATURE_SUMMARY -- 2-3 sentences}

Branch: `{BRANCH}` | PR: #{PR_NUMBER} | Generated: {YYYY-MM-DD}
Target runtime: ~{N} min

---

## Briefing (read this off-camera first)

Read this before hitting record. Get your head in the space of what you're
showing and why it matters.

- **What changed:** {one line}
- **Why it matters:** {who benefits and how}
- **Happy path:** {end-to-end flow in one sentence}
- **Key emphasis:** {the 1-2 things that should land with the viewer}
- **Technical callout:** {architecture or implementation detail worth noting for engineers}
- **Known gaps:** {what's NOT in this PR, if relevant}
- **Before state:** {what the user experience was before this change, if applicable}
- **After state:** {what the user experience is now}

---

## Prerequisites

- Dev server running (`{dev_command}`)
  {each prerequisite as a bullet}

---

## Walkthrough

When you're ready to record (or QA), invoke this skill and say "go". Each
step will be presented one at a time. Say "next" to advance.

### Step 1: {Step Title}

**Go to:** `{url_or_route}`
**Do:** {specific action -- what to click, type, or trigger}
**Emphasize:** {the talking point -- what matters here, not what to say}
**QA check:** {expected visible outcome for verification}

### Step 2: {Step Title}

**Go to:** `{url_or_route}`
**Do:** {specific action}
**Emphasize:** {talking point}
**QA check:** {expected outcome}

{repeat for 4-8 steps}

---

## Gotchas

{each gotcha as a bullet, or "None identified." if empty}

---

## Cleanup

{teardown steps, or "No cleanup needed." if none}
```

### Content Rules

1. **5-minute max.** 4-8 steps, ~30-45 seconds each. Cut ruthlessly. Show the happy path and one edge case, not exhaustive coverage.
2. **Talking paper, not teleprompter.** "Emphasize" lines are what to highlight, not words to read. Example: "Emphasize: instant feedback, no full-page reload" -- NOT "Say: as you can see, we've implemented real-time validation..."
3. **Dual audience in one pass.** Technical viewers get the "QA check" line. Non-technical viewers get the "Emphasize" line. Both see the same demo.
4. Steps must reference **actual URLs, button text, and field labels** from the code -- not placeholders.
5. Include **specific test data** where applicable (email addresses, names, search terms).
6. If the PR body or commits mention edge cases worth showing, include them as optional bonus steps at the end under a "## Bonus (if time)" section.
7. Omit the PR line from the header if no PR exists.
8. Keep the entire generated skill under 120 lines -- concise and scannable.

### Interactive Walkthrough Behavior

When the generated demo skill is **invoked** (not generated -- invoked by a user in the target repo):

1. Print the **Briefing** section in full. This is the off-camera prep.
2. Use **AskUserQuestion**: "Ready to start the walkthrough? (say 'go' when recording)"
3. Present **Step 1** only.
4. Use **AskUserQuestion**: "Next step? (say 'next', or ask me anything about this step)"
5. Present **Step 2**. Repeat until all steps are shown.
6. After the final step, print: "That's a wrap. {N} steps in ~{estimated_minutes} min."

This incremental delivery means the user can pace the demo naturally, pause to narrate, or ask clarifying questions mid-flow.

### Update Mode Merging

When updating an existing skill:

1. Read the existing SKILL.md
2. Preserve the existing `name` and `description` frontmatter (unless the feature scope changed materially)
3. Update the `Generated` date
4. Regenerate the Briefing section from scratch (it should always reflect current branch state)
5. For each existing step: if the route/action still exists in the diff, keep the step (update if behavior changed)
6. For new routes/features in the diff: add new steps at the appropriate position in the flow
7. For routes/features removed from the diff: remove the corresponding steps
8. Re-validate the 5-minute budget after merging. Cut if over 8 steps.
9. Preserve any section the user manually added that is not part of the template (identified by headers not in the template)

---

## Phase 7 -- Write & Confirm

### Dry-run mode (`--dry-run`)

Print the generated SKILL.md content to the terminal inside a fenced code block. Do NOT write any files. Print:

```
DRY RUN -- no files written.
Would write to: {SKILL_PATH}
```

Stop here.

### Write mode (default)

1. Create the directory if needed:

```bash
mkdir -p "{SKILL_DIR}"
```

2. Write the generated content to `$SKILL_PATH` using the Write tool.

3. Create a symlink for Claude Code slash-command discovery:

```bash
mkdir -p ".claude/commands"
ln -sf "../../${SKILL_DIR}/SKILL.md" ".claude/commands/${APP_ID}:demo:${FEATURE_NAME}.md"
```

This makes the skill discoverable via `/` autocomplete in Claude Code while keeping the canonical file in `.agents/skills/` for cross-agent compatibility (e.g., OpenAI Codex).

4. Print the output contract:

```
DEMO SKILL GENERATED
--------------------
Path:     {SKILL_PATH}
Skill:    /{APP_ID}:demo:{FEATURE_NAME}
Feature:  {FEATURE_NAME}
Mode:     {created | updated}
Steps:    {N}
Est. runtime: ~{N} min

Symlink: .claude/commands/{APP_ID}:demo:{FEATURE_NAME}.md → {SKILL_PATH}

Ready to commit with your feature branch:
  git add "{SKILL_PATH}" ".claude/commands/${APP_ID}:demo:${FEATURE_NAME}.md"

To run the demo:
  /{APP_ID}:demo:{FEATURE_NAME}
```

---

## Error Handling

| Condition                            | Action                                                          |
| ------------------------------------ | --------------------------------------------------------------- |
| Not a git repo                       | Stop: "Not a git repo."                                         |
| On default branch, no changes        | Stop: "No feature branch changes to demo."                      |
| No changed files on branch           | Stop: "No changes found on this branch."                        |
| `gh` not available                   | Continue without PR context; derive from commits only           |
| `.agents/skills/` does not exist     | Create it                                                       |
| Skill already exists (no `--update`) | Ask: "Demo skill already exists. Update it?"                    |
| No routes or UI files in diff        | Generate a minimal skill with API/backend-focused steps instead |
| User cancels at any AskUserQuestion  | Stop gracefully                                                 |
| More than 8 steps after synthesis    | Cut to 8. Move extras to "Bonus (if time)" section.             |
