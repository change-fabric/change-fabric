# /pst reference

Mechanics and detail for the `/pst` skill. Not loaded as doctrine; read it only
when you need specifics. Rule numbers match `SKILL.md`.

## Merge modes (asked at every invoke)

`/pst` asks via `AskUserQuestion` how PRs should land this session, re-asking on
every re-invocation so it can change per repo:

1. **Admin-bypass squash:** `gh pr merge <pr> --squash --admin` as PRs go green.
   For repos you can self-merge.
2. **Auto-merge on approval:** `gh pr merge <pr> --auto --squash`. GitHub merges
   each PR once required approvals and checks pass. For approval-gated repos (for
   example REDACTED, where Conner must approve).
3. **Merge-ready only:** bring PRs to merge-ready, do not enable auto-merge, do
   not admin-bypass; leave the merge to the user.
4. **Local only (rule 18):** never push a branch or touch a remote PR/issue; all
   work stays in local git worktrees and commits, enforced by the guard. The
   intended workflow: validate a complex feature set end to end in the local k3s
   cluster before any GitHub round-trip. Build it across stacked local feature
   branches, deploy to an arbitrary `*.pstaylor.net` subdomain, prove it there
   (rules 8, 14), and only afterward reconcile the stack into real GitHub PRs by
   re-invoking `/pst` under another merge mode. `pst-mode.rb local on` arms it;
   bootstrap clears the marker each invoke, so it resets unless re-selected.

## Deterministic gates in pst-guard.rb (PreToolUse, armed only)

- **No em dash (rule 11):** denies Write/Edit content or git commit messages
  containing U+2014.
- **Model tier (rule 2):** denies an `Agent`/`Task` spawn whose `tool_input.model`
  is unset. Only model is enforceable (effort is not a spawn parameter). Denies
  only when model is absent, so it never blocks a spawn that sets one. Override
  `PST_ALLOW_DEFAULT_MODEL=1`.
- **Merge gate (rules 5 and 7):** intercepts a direct `gh pr merge`:
  - CI (rule 5): runs `gh pr checks`; blocks unless all pass (pending or failing
    block). No checks: allow. Unverifiable (timeout/error): deny. Override
    `PST_ALLOW_RED_MERGE=1`.
  - Review (rule 7): blocks unless a review marker exists for the head commit
    (`pst-reviewed.rb mark`). Override `PST_ALLOW_UNREVIEWED_MERGE=1`.
  - `--auto`: allowed; GitHub holds the merge until its own approval and checks
    gate is satisfied (merge mode 2).
- **Local-only (rule 18, merge mode 4):** when local-only is armed for the
  session, denies any remote-mutating command: `git push`, `gh pr
create|merge|ready|edit|comment|close|reopen`, and `gh issue
create|edit|comment|close|reopen`. Read commands (`gh pr view|checks|list`) are
  unaffected, so local CI inspection and review still work. Armed with
  `pst-mode.rb local on`, reset on each bootstrap. Override `PST_ALLOW_REMOTE=1`.

Example override: `PST_ALLOW_RED_MERGE=1 PST_ALLOW_UNREVIEWED_MERGE=1 gh pr merge 53 --squash --admin`.

## Deterministic helper scripts (Ruby)

- `scripts/pst-mode.rb` bootstrap: install shim, git identity guard, arm session
  (`off` disarms; `foreground on|off` toggles the delegate-nudge escape hatch;
  `local on|off` toggles merge-mode-4 local-only remote-mutation enforcement).
- `scripts/register-hooks.rb` idempotently registers the shim in settings.json.
- `scripts/pst-emdash.rb check|prune [path ...]` finds or strips em dashes.
- `scripts/pst-worktrees.rb [repo_dir]` lists prunable worktrees (rule 4).
- `scripts/pst-reviewed.rb mark|check [sha]` records or checks the review marker
  the merge guard requires (rule 7).
- `scripts/hooks/*.rb` installed hook bodies plus `pst_common.rb` (shared lib).

## Rule detail and examples

- **Rule 2 tiers, Haiku fits:** mechanical rename or import-path rewrite, lint or
  format autofix, single-string copy change, version or changelog bump, deleting
  already-identified dead code, boilerplate from an exact template.
- **Rule 6 band-aids to avoid:** skipping tests, loosening thresholds,
  retry-until-green, swallowing errors.
- **Rule 8 local k8s timing:** inspect `.github/workflows/`. If merge auto-deploys
  to remote, do the local blue-green deploy and E2E validation BEFORE merge so
  remote is never reached unvalidated; otherwise validate post-merge but
  pre-promotion. The local k3s cloud is a safe sandbox (no VPC or
  deploy-permission roadblocks), so heavyweight automated testing is feasible.
- **Rule 13 cue phrases:** "don't stop until you're done", "all the way", "keep
  going till it's green".
- **Rule 15 smell vocabulary:** long method, large class, feature envy, primitive
  obsession, shotgun surgery, divergent change, data clumps, message chains,
  speculative generality.
- **Rule 17 open-on-post triggers:** `gh pr create`, `gh pr|issue comment`,
  `gh pr|issue edit --body`, and the Jira `createJiraIssue` / `editJiraIssue` /
  `addCommentToJiraIssue` MCP tools. It opens the GitHub URL scraped from command
  output, or a Jira browse URL built from the response host plus the issue key
  (from the input for edit/comment, from the response for create). Scans only the
  tool response, so a URL inside a comment body is not opened by mistake. Uses
  macOS `open` (else `xdg-open`); set `PST_NO_BROWSER=1` to skip a run.

## Session hooks

`scripts/pst-mode.rb` installs Ruby scripts (and `pst_common.rb`, the shared lib)
to `~/.claude/pst/bin/` and registers them once in `~/.claude/settings.json`:

- `pst-session-start.rb` (`SessionStart`) writes `CLAUDE_SESSION_ID` into
  `$CLAUDE_ENV_FILE` so a skill can learn its own session id.
- `pst-guard.rb` (`PreToolUse`) runs the em-dash, model-tier, and merge gates
  above, only when armed.
- `pst-prompt-reminder.rb` (`UserPromptSubmit`) re-injects the compressed rule
  checklist each turn, leading with the delegate-by-default test (rule 1), only
  when armed. Drops the delegation lead under foreground mode.
- `pst-delegate-nudge.rb` (`PostToolUse`, `Write|Edit|MultiEdit`) counts inline
  implementation edits and, after the 3rd, surfaces a non-blocking reminder to
  delegate (rule 1). Never blocks. See "Delegation and foreground mode".
- `pst-open-on-post.rb` (`PostToolUse`, `Bash` and the Jira create/edit/comment
  MCP tools) opens the resulting page in the browser after an action under
  Patrick's name: a PR created, a PR/issue or Jira comment posted, a Jira issue
  created, or a description updated (rule 17). Side effect only, never blocks.
  Skip a run with `PST_NO_BROWSER=1`.
- `pst-session-end.rb` (`SessionEnd`) removes the per-session marker.

### Delegation and foreground mode

The delegate nudge counts only foreground grunt work: an edit counts only when
the file is in the **primary** git worktree. Delegated work runs in linked
worktrees (rules 2, 3), so those edits are never counted, which makes the nudge
correct whether or not sub-agents share the parent session id. It also skips
`*.md`, docs, lockfiles, `*.tfvars`, JSON/YAML/TOML config, and dotfiles, and
edits outside a repo (favoring under-counting). It is non-blocking and resets its
per-session counter after each reminder. Set `PST_DEBUG_DELEGATE=1` to log each
edit's session id, primary-worktree verdict, cwd, and path to
`~/.claude/pst/delegate/debug.log` for verification. Silence it when foreground
work is intentional (a planning or conversation-heavy session) via either:

- `pst-mode.rb foreground on` (creates `~/.claude/pst/foreground/<sid>`; `off`
  removes it). This also drops the per-turn reminder's delegation lead.
- env `PST_FOREGROUND_OK=1` for a single command.

A session is armed only if `~/.claude/pst/armed/<session_id>` exists, which
`/pst` creates (`/pst off` removes it). Otherwise the hooks are inert. Because
Claude Code binds hooks at session startup, in the session that first installs
the shim the guards engage from the next session onward; later sessions arm
immediately.

## Rule 20: OrbStack Docker for ephemeral infra

All common dev services (Postgres, Redis, RabbitMQ, etc.) run as OrbStack Docker containers. Never install them natively or spin up bare k3s services for local dev.

**Starting a tracked Postgres container:**

```sh
docker run -d --name myapp_pg_dev \
  -e POSTGRES_PASSWORD=devpass -e POSTGRES_DB=myapp_dev \
  -p 5432:5432 postgres:16
ruby scripts/pst-docker.rb register myapp_pg_dev
```

The session-end hook reaps it automatically via `docker stop` + `docker rm`.

**One-shot containers** (script runs, exits, gone): use `docker run --rm ...`. No tracking needed; Docker cleans up on exit.

**Helper: `scripts/pst-docker.rb`**

- `register <name-or-id>` -- append to `~/.claude/pst/docker/<session_id>`
- `reap` -- stop and remove all tracked containers immediately (useful if you want to clean up mid-session)
- `list` -- show what is currently tracked

**Override:** `PST_KEEP_DOCKER=1` skips the reaper at session end (e.g., you want the container to survive for debugging).

## Three-agent sequence (rule 19)

Default pattern for any feature or fix. Sequential: each stage feeds the next. Haiku helper stages (0.5, 1.5, 2.5, 3.5, 4.5) do mechanical and compression work around the three thinking tiers so Opus and Sonnet tokens stay on reasoning and implementation. Stage 0 (Haiku classifier) gates the whole pipeline.

**Stage 0: Haiku classifier** (background, model: haiku, effort: low)
Gates the pipeline. Returns `trivial` or `substantive` based on the incoming request alone. Trivial tier is wired to the rule-2 Haiku-fits list (see "Rule detail and examples"). On any doubt, returns `substantive`.

Sample prompt:

```
Classify this engineering request as trivial or substantive.

trivial = a clear match to one of these (and nothing more): mechanical rename or
import-path rewrite; lint or format autofix; single-string copy change; version
or changelog bump; deleting already-identified dead code; boilerplate from an
exact template.

substantive = anything else, or any doubt.

Request:
<request text>

Return only JSON: {"verdict":"trivial"|"substantive","rationale":"<= 80 chars"}.
```

Output schema: `{ "verdict": "trivial" | "substantive", "rationale": "string <= 80 chars" }`.

**Stage 0.5: Haiku pre-flight context assembler** (background, model: haiku)
Runs after the classifier routes to the pipeline, before the planner. Scouts the repo so Opus spends tokens reasoning, not discovering.

Sample prompt: "Scout this repo for the request below: list the directory tree (depth 2), the last 15 git log lines, and the full contents of the most relevant files. Return only the bundle, no commentary. Request: `<request>`."

Output schema: `{ "tree": string, "git_log": string, "key_files": [ { "path": string, "content": string } ] }`. The planner receives this bundle as its repo context.

**Stage 1: Opus planner** (background, model: opus, effort: high)
Prompt it with the full request and the Stage 0.5 context bundle. Output: a numbered, step-by-step implementation plan with file targets and acceptance criteria.

**Stage 1.5: Haiku plan distiller** (background, model: haiku)
Compresses the verbose Opus plan into the exec summary the plan gate shows. Haiku compresses; Opus thinks.

Sample prompt: "Compress this implementation plan into a single summary of 320 characters or fewer that names what changes and the main files touched. No em dashes. Plan: `<plan>`."

Output schema: `{ "summary": string }` where `summary` is at most 320 characters and contains no U+2014.

**Stage 2: Plan gate** (foreground AskUserQuestion)
Show the Stage 1.5 distilled summary (320 characters max). Up to two follow-up questions if scope or approach needs settling. On approval (or no objection), proceed. On rejection, loop back to Stage 1 with the feedback.

**Stage 2.5: Haiku test scaffolder** (background, model: haiku, isolated worktree)
After gate approval, before implementation. Turns the plan's acceptance criteria into failing test stubs and fixture files so the implementer has a concrete target.

Sample prompt: "From these acceptance criteria, write test stubs and fixture files in the project's test framework. Stubs must assert the criteria and fail until implemented. Do not write production code. Criteria: `<criteria>`."

Output: test and fixture files committed in the worktree, plus `{ "files": [string], "framework": string }` passed to the implementer. Stage 3 continues in this same worktree so the implementer inherits the committed stubs.

**Stage 3: Sonnet implementer** (background, model: sonnet, effort: medium, same worktree as Stage 2.5 (inherited from the test-scaffolding commit))
Receives the approved plan verbatim plus the scaffolded tests. Implements exactly that plan: no scope additions, no creative departures, making the stubs pass. Commits in the worktree.

**Stage 3.5: Haiku lint/format pass** (background, model: haiku, same worktree)
After implementation, before validation. Mechanical cleanup so the validator focuses on correctness: em-dash check (`scripts/pst-emdash.rb check|prune`), import sorting, trailing whitespace, obvious style. No behavior changes.

Sample prompt: "In this worktree run the project formatter and import sorter, strip trailing whitespace, and run `scripts/pst-emdash.rb prune` on changed files. Report only what you changed. Change no behavior."

Output schema: `{ "changed_files": [string], "emdash_hits": number, "notes": string }`.

**Stage 4: Opus validator** (background, model: opus, effort: high)
Verifies: (1) every plan step was addressed, (2) no regressions introduced, (3) smoke/integration tests pass. If issues are found, applies fixes before reporting. Final report goes to Patrick.

**Stage 4.5: Haiku commit message writer** (background, model: haiku)
After validation passes. Reads the diff and the original plan, writes a conventional-commit message. Deterministic, well-scoped.

Sample prompt: "Write a conventional-commit message for this diff. Use the plan for intent. Subject under 72 chars, imperative mood, no em dashes. Body: what changed and why. Diff: `<diff>`. Plan: `<plan>`."

Output schema: `{ "subject": string, "body": string }`. The orchestrator appends the rule-10 co-author trailer before committing.

**Trivial threshold (skip the pipeline)**
The Stage 0 Haiku classifier owns this decision. It returns `trivial` only on a clear match to the rule-2 Haiku-tier list: mechanical rename, import-path rewrite, lint/format autofix, single-string copy change, version or changelog bump, deleting already-identified dead code, or boilerplate from an exact template. Any doubt returns `substantive`, making the pipeline the default.

## Order of operations for a typical change

0. Run the pipeline before opening a PR: Haiku classify, Haiku pre-flight, Opus plan, Haiku distill, plan-gate approval, Haiku scaffold tests, Sonnet implement, Haiku lint/format, Opus validate, Haiku commit message (rule 19). Haiku stages handle mechanical work; Opus and Sonnet own thinking and implementation.
1. For feature/fix work, planning and validation run as rule-19 pipeline stages (background Opus); the foreground keeps only orchestration, choices, and gate decisions. For all other work, plan in the foreground (Opus high) and fan implementation out to background Sonnet agents in isolated worktrees (rules 1, 2, 3).
2. Open a PR (rule 5). Separate refactor commits from behavior changes (rule 15).
3. Get CI green with root-cause fixes (rules 5, 6). De-slop the diff (rule 12).
4. Run adversarial review; implement findings; re-review to clean (rule 7).
5. For a cluster app, run the local k8s QA arsenal with discernment and prove it
   works end-to-end (rules 8, 9, 14). If CI auto-deploys to remote on merge, do
   this BEFORE merge via blue-green.
6. Land by the chosen merge mode: admin-bypass squash on green CI, auto-merge on
   approval, or hand off merge-ready (rule 5, merge-guard enforced).
7. If not gated pre-merge, validate locally before any remote promotion (rule 8).
8. Run `pst-worktrees.rb` and offer to prune orphaned worktrees (rule 4).
