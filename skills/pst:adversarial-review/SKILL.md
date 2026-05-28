---
name: pst:adversarial-review
description: Plan a subject, emit an adversarial-review prompt + changelog stub, and eagerly implement on a draft PR
argument-hint: "<what-to-plan-and-build> [--impl-now|--no-impl]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Skill
---

# Adversarial-review-driven plan + build

Take a subject/goal, produce a **phased plan**, hand the user a self-contained
**adversarial-review prompt** to run against another model (Codex, etc.), open a
**changelog stub** for that reviewer to fill, then **eagerly implement the plan
on a dedicated draft PR without waiting for the review to come back**. When the
user returns the changelog, fold its fixes into both the plan and the in-flight
implementation.

The premise: the slowest part of a high-quality build is round-tripping a plan
through critique. So run the critique **in parallel** with implementation: start
building the low-churn foundations immediately (they rarely change), and absorb
the adversarial findings as they arrive.

## Division of labor (deterministic script vs. model)

The mechanical, repetitive, error-prone steps are owned by a tested Python
helper so they are fast, predictable, and idempotent. The creative work stays
with you. This mirrors `/plan-io`: the builder assembles, the model authors.

| Owned by `scripts/adversarial_review.py` (deterministic)     | Owned by you (semantic)                          |
| ------------------------------------------------------------ | ------------------------------------------------ |
| slug + path + branch/base derivation                         | the PLAN body (every section)                    |
| writing the CHANGELOG stub + prompt template + plan skeleton | the prompt's **Context** paragraph               |
| idempotent scaffold writes (never clobbers your prose)       | the actual implementation, foundations-first     |
| worktree + branch creation (suffix-bump on collision)        | reconciling a returned changelog into code edits |
| push + draft-PR creation (reuses an existing PR)             | judgment calls everywhere                        |
| parsing the reviewer's changelog into structured entries     |                                                  |

Run the script for the table's left column; do the right column yourself. Never
re-derive slugs/paths in bash or hand-craft the PR-creation dance: that is what
the script exists to make idempotent.

---

## Quick reference

```bash
/pst:adversarial-review "a rate limiter for the public API"        # plan + review prompt + start building
/pst:adversarial-review "migrate auth to Better Auth" --no-impl    # plan + review prompt only, do NOT start building yet
/pst:adversarial-review "redesign the billing webhook handler" --impl-now  # skip confirmation, jump straight to implementation
/pst:adversarial-review <changelog-path-or-paste>                  # second invocation: apply returned changelog to plan + impl
```

Three artifacts get written to a per-subject working dir and opened in VS Code:

| File                           | Who writes it                                             | Purpose                                                                         |
| ------------------------------ | --------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `PLAN.md`                      | script scaffolds headers; you fill; reviewer edits inline | phased plan: scope, design options + recommendation, risks, acceptance criteria |
| `ADVERSARIAL-REVIEW-PROMPT.md` | script (template); you fill the Context slot              | self-contained prompt to paste into another model                               |
| `CHANGELOG.md`                 | script scaffolds the stub; the reviewer fills it          | one entry per change, with rationale                                            |

Flags: `--impl-now` skips the "start building?" confirmation; `--no-impl`
produces the three artifacts and stops (no PR yet).

## Resolve the bundled script (run once, harness-neutral)

The deterministic helper ships alongside this file at
`scripts/adversarial_review.py`. Resolve it the same way `pst:secrets` does, so
it works whether the skill was installed for Claude Code (file symlink), Codex
(directory symlink), or run straight from the repo:

```bash
SKILL_LINK="$HOME/.claude/commands/pst:adversarial-review.md"
if [ -L "$SKILL_LINK" ]; then # Claude Code: file symlink
  SCRIPTS="$(dirname "$(readlink -f "$SKILL_LINK")")/scripts"
elif [ -n "$CODEX_HOME" ] && [ -d "$CODEX_HOME/skills/pst:adversarial-review/scripts" ]; then
  SCRIPTS="$CODEX_HOME/skills/pst:adversarial-review/scripts" # Codex: dir symlink
else
  SCRIPTS="$(dirname "${BASH_SOURCE[0]:-$0}")/scripts" # repo / Pi wrapper
fi
AR="$SCRIPTS/adversarial_review.py"
```

Every deterministic step below invokes `python3 "$AR" <subcommand>`.

---

## Step 1 - scaffold the artifacts (deterministic)

Run `init` with the subject. It derives the slug, working dir (prefers
`<repo>/docs/plans/<slug>/`, falls back to a scratch dir outside the repo when
there is no `docs/`), branch, and base; writes the CHANGELOG stub, the prompt
template (with a `{{CONTEXT}}` slot), and a headers-only PLAN skeleton; and
prints a JSON manifest. Re-running is safe: it never overwrites files you have
already authored (pass `--force` only if you mean to reset them).

```bash
python3 "$AR" init "<subject>" --json
```

Capture the manifest (it carries `slug`, `workdir`, `plan_path`,
`prompt_path`, `changelog_path`, `branch`, `base`, `impl_dir`,
`context_slot`). Tell the user the chosen `workdir` and slug. If the manifest
shows a `docs/plans/` path and the user does not want plans committed, re-run
with an explicit `--workdir` pointing outside the repo.

---

## Step 2 - author the PLAN body (your job)

The skeleton in `plan_path` has the required headers and `_(fill in)_` markers.
**Edit it into a genuine plan** (do not leave placeholders). Required sections,
already stubbed:

- **Subject / goal** - one paragraph restating what we are building and why.
- **Scope** - explicit in-scope and out-of-scope bullets (out-of-scope is what
  stops scope creep; be generous).
- **Phases** - numbered, each with objective, concrete tasks, files touched, and
  a churn-risk estimate (low/medium/high; drives build order).
- **Design options + recommendation** - at least two viable approaches with
  tradeoffs, then a clear recommendation and the reasoning.
- **Risks & failure modes** - correctness, security, perf, data loss, scope,
  ops; each with a mitigation.
- **Acceptance criteria** - testable, checkbox-style. This is what "done" means.
- **Open questions** - anything genuinely undecided.

Then fill the prompt's Context slot: open `prompt_path` and replace the
`{{CONTEXT}}` line with a self-contained briefing (what the project is, the
stack, constraints, and the goal) so the reviewer needs nothing else.

---

## Step 3 - open the three artifacts (deterministic)

```bash
python3 "$AR" open --workdir "<workdir>"
```

This opens `PLAN.md` fresh and the prompt + changelog with `code -r` (reusing the
window). If the `code` CLI is unavailable it prints the paths to open manually.

Tell the user: "Paste `ADVERSARIAL-REVIEW-PROMPT.md` into Codex/another model
pointed at `<workdir>`. When it returns the edited plan + changelog, re-run
`/pst:adversarial-review <changelog-path>` and I will fold the fixes in."

If `--no-impl` was passed, **stop here**. Otherwise continue to Step 4.

---

## Step 4 - eagerly implement on a dedicated draft PR (do NOT wait for the review)

This is the point of the skill: build in parallel with the critique. Unless
`--impl-now` was passed, confirm once ("Start implementing now on a draft PR
while the review runs?"), then proceed.

### 4a. Create the worktree + branch (deterministic)

```bash
python3 "$AR" start-impl --slug "<slug>" --json
```

This fetches origin, picks the base (repo default branch), creates
`feat/<slug>` (bumping a numeric suffix if it already exists), and adds an
isolated worktree under `.worktrees/<slug>`. It prints `{branch, base,
impl_dir}` - use `impl_dir` as the working directory for all implementation
commits so the user's current checkout is undisturbed.

### 4b. Build order - foundations first (your job)

Implement **lowest-churn phases first** (the ones the adversarial review is least
likely to overturn): types/interfaces, schema, config scaffolding, pure helper
functions, test harness. Defer anything the review might reshape (public API
surface, contentious design choices) until either the changelog lands or it
becomes blocking. Commit incrementally with conventional messages:

```bash
git -C "<impl_dir>" add <specific files>
git -C "<impl_dir>" commit -m "feat(<slug>): <phase objective>"
```

### 4c. Open the draft PR (deterministic)

```bash
python3 "$AR" pr --slug "<slug>" --subject "<subject>" --workdir "<workdir>" \
  --plan-path "<plan_path>" --changelog-path "<changelog_path>" \
  --branch "<branch>"
```

This pushes the branch and creates a **draft** PR (heredoc body, never an escaped
`--body`), then opens it in the browser. It is idempotent: if a PR already exists
for the branch it reuses it instead of erroring. Pass `--no-open` to skip the
browser.

> **Optional - delegate to a background agent.** The implementation can be handed
> to a background agent running in the `impl_dir` worktree so it proceeds while
> the user runs the adversarial review elsewhere. If you do this, hand the agent
> the plan path, branch, base, and the "foundations-first" build order, and have
> it commit incrementally and keep the draft PR updated.

---

## Step 5 - adapt when the changelog returns (second invocation)

When the user re-runs `/pst:adversarial-review <changelog-path-or-paste>`:

1. **Parse the changelog (deterministic).** Turn the reviewer's prose into
   structured entries:

   ```bash
   python3 "$AR" parse-changelog "<changelog-path>" --json   # or: ... parse-changelog - < paste
   ```

   Each entry is `{what, why}`. An entry with an empty `why` is flagged so you
   can push back (the prompt forbids rationale-free changes).

2. **Reconcile the plan.** The reviewer edited `PLAN.md` inline; confirm those
   edits are coherent and resolve any conflicts with what you have already built.
3. **Apply fixes to the in-flight implementation eagerly.** For each parsed entry
   that affects code, make the change in `impl_dir`, commit it with a message
   referencing the rationale (e.g.
   `fix(<slug>): tighten X per adversarial review - <why>`), and update the draft
   PR's test plan if acceptance criteria changed.
4. **Push and refresh.** `git -C "<impl_dir>" push --force-with-lease` if you had
   to rewrite history; otherwise a normal push. Refresh the PR body via
   `gh pr edit --body-file` (heredoc), then `gh pr view --web`.
5. **Flip out of draft** once the foundations + adversarial fixes are in and the
   acceptance criteria are met: `gh pr ready`.

---

## Conventions (this repo / Patrick)

- The deterministic mechanics live in `scripts/adversarial_review.py`; the unit
  tests in `tests/test_adversarial_review.py` cover the pure logic (run with
  `pytest skills/pst:adversarial-review/tests -q`). Keep them green when editing.
- No em dashes anywhere in tracked files (CI enforces this); use a hyphen or
  rephrase.
- VS Code via the `code` CLI; `code -r` to reuse the window for extra tabs.
- PR/issue bodies via `--body-file` with a heredoc, never `--body "...\n..."`.
- Updates that rewrote history use `git push --force-with-lease`, never `--force`.
- Keep generated paths runtime-derived; never hardcode machine-specific absolutes.
- Do not commit secrets or scratch plan files you did not mean to (the scratch
  dir default lives outside the repo).

```

```
