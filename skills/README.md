# Skills

Each subdirectory is a Claude Code skill (`SKILL.md` with YAML frontmatter).
`install.rb` symlinks every one into `~/.claude/skills/`, so they are all
invocable directly (e.g. `/cf:refactoring`). Re-running it also prunes its own
stale links: a symlink into this repo's `skills/` with no matching source (a
renamed or deleted skill) is removed, while real dirs and links into other
repos are left alone.

Directory names stay plain and portable (no colons committed to git). The
`cf:` namespace lives only in each skill's frontmatter `name:`, which is what
`SkillRegistry` and Claude Code resolve by; `install.rb` names the symlink from
that single source. `cf` itself is the namespace root and stays unprefixed.

Skills fall into two kinds, by whether they carry an `auto:` block.

## Command skills (manually invoked)

A skill with no `auto:` block is a command: it runs only when you invoke it, and
the hooks never surface it. These are verbs the agent performs on demand.

| Skill | Does |
|---|---|
| `cf` | Manual two-question picker for both session axes: merge mode and away mode. Sets and enforces both. |
| `cf:local-only` | Direct command: sets merge mode to local only. No push, no PR. |
| `cf:merge-ready` | Direct command: sets merge mode to merge ready. Push branch, open PR, ensure CI green, stop before merging. |
| `cf:admin-bypass` | Direct command: sets merge mode to admin bypass. Push, open PR, then squash-merge via admin bypass once CI is green. |
| `cf:yolo` | Direct command: sets merge mode to yolo. Commit and push straight to the target branch, never `gh pr create`. |
| `cf:away` | Direct command: sets away mode on. Stops asking questions, takes the recommended or safe default, and reports what was assumed. |
| `cf:active` | Direct command: sets away mode off, so the agent asks normally again. |
| `cf:refactor` | Refactors a scope you name (PR, branch, repo, file, or glob), routing each file through the auto-firing skills that cover it. |
| `cf:code-review` | Reviews a scope you name (PR, branch, files, or a feature description), verifies each candidate finding in an isolated worktree, and posts only what survives. Posts by default (`--signoff` asks first); on a second round it posts one consolidated root-cause review instead of more inline comments. |
| `cf:ctx` | Captures, recalls, and lists durable project context in the shim-owned .ctx store. |
| `cf:prune` | Post-merge cleanup: fast-forwards the trunk and prunes merged branches and worktrees, local and remote, asking before it discards unmerged work or deletes any remote branch. |
| `cf:resolve-threads` | Resolves every unresolved review thread on a PR, each evaluated in its own isolated worktree with the run's other threads and earlier fixes in view; fixes every instance of the bug class, dismisses, or defers to a human, then replies, resolves and pushes by default (`--signoff` asks first). Recurring feedback triggers a root-cause pass: a small cause is fixed in one commit, a large one starts cf:plan. |
| `cf:qa` | Scopes and runs an ad hoc Playwright QA pass against a natural-language target (a PR, a feature, a flow) in an ephemeral browserless Chromium container, and posts findings as PR comments by default (`--signoff` asks first). |
| `cf:screenshot` | Captures before/after screenshots of every configured route and viewport at two git refs, keeps only the pairs that pixel-differ, uploads them to GitHub, and splices them into the pull request body's Demo section. |
| `cf:change` | Runs the deterministic, config-driven release-gate sweep (all five dockerized audit lanes: k6 load, axe-core a11y, OWASP ZAP pentest, browserless responsive UX, committed test cases) against a project's root `CHANGE.md` (its `change_config:` frontmatter), aggregates a CSV+Markdown report on the Desktop, and records a pass/fail gate for the head commit. |
| `cf:drive` | Drives a PR to an approved, green state end to end. `thorough` (default) interviews the owner, writes a review-and-QA planning set, and prints a handoff prompt for a fresh session. `quick` sweeps review threads, runs a relevance-gated local quality loop, predicts CI locally, then pushes, waits for real CI, and posts an approval; it runs straight through by default (`--signoff` adds checkpoints), and stops to start cf:plan when review feedback recurs. |
| `cf:k6` | Runs just the k6 load/burst lane of the change-fabric platform against a project's config. |
| `cf:a11y` | Runs just the axe-core accessibility lane of the change-fabric platform against a project's config. |
| `cf:zap` | Runs just the OWASP ZAP penetration-test lane of the change-fabric platform against a project's config. |
| `cf:testcases` | Runs just the deterministic regression lane of the change-fabric platform: replays the test cases committed in the repo's suite files and grades each one. On a failed grade it reports the override command instead of asking (`--signoff` asks). |
| `cf:sweep` | Sweeps a repo's open feature PRs and plans how to land them as a group, covering merge order, conflict mitigations, migration sequencing, and a per-contributor trust policy persisted across runs. Runs in `auto` mode by default; merge mode still gates every merge. |
| `cf:plan` | Researches a goal with background Opus agents, grills the user with AskUserQuestion until the judgment calls are settled, then lands a plan.md, a 4000-character-capped goal.md, and a runnable workflow.js under `$CF_PLANS_ROOT` (default `~/.claude/cf/plans`), plus a handoff prompt for a separate session to execute. |
| `cf:color` | Direct command: audits a repo's colors against a four-color minimal system and consolidates as far as you approve. Opt-in, for when you are driving a color outcome. |
| `cf:status` | Arms a recurring self-status ping on a real cron loop (`/cf:status [<minutes>]`) and prints a red/yellow/green progress line per active work item on each `/cf:status tick`, only when something changed, stopping itself once every item is green. |

`cf:refactor` reuses the routing below by shelling out to `skill_route.rb`
(`scripts/skill_route.rb`, copied to the shim bin but not wired as a hook): it
maps a changeset's files to the skills that match, so a one-shot refactor
applies the same rubrics the per-edit hooks would.

`scripts/thread_history.rb` reads a PR's review history from
GitHub (rounds per reviewer, earlier fixes, a prior cf:code-review round)
for cf:resolve-threads and cf:code-review.

## Auto-firing skills

A skill becomes **auto-firing** by adding an `auto:` block to its frontmatter.
The cf shim then surfaces it without anyone invoking it:

- **Per-edit routing** (`skill_inject.rb`, PostToolUse) is deterministic
  file-type matching. On every edit whose path matches, the skill's body is
  injected once per session. This is "runs on every Ruby change, no matter
  what" - it does not depend on project detection.
- **Project fingerprint** (`skill_detect.rb`, SessionStart) is a deterministic
  marker-file scan that announces which skills apply, once per session. Project
  type is a file-presence question (`Gemfile`, `*.gemspec`), so it needs no LLM.
- **Review** runs a model against the changed files. Every matching skill is
  reviewed; the scope only frames what counts as in-bounds. `all_code` and
  `extensions` skills review code (the prompt tells the reviewer to skip files
  that merely look like code), while `all_files` skills (`cf:ai-slop`) review
  every changed file, prose and documentation included. As you edit,
  `skill_inject.rb` queues every changed file each matching skill covers, except
  files in a detached-HEAD linked worktree, the disposable kind cf:resolve-threads
  and cf:code-review create per finding, which are never published. A linked
  worktree on a branch is publishable and stays reviewed. `skill_review.rb` (Stop)
  and `review_gate.rb` (PreToolUse on push or PR create) both read the queue
  without draining it and block or deny while it is non-empty and not capped for
  the current batch fingerprint, handing the agent a fixed prompt - the skill's
  principles plus the changed file list - to run a haiku background-agent review.
  Only `review_ack.rb` drains the queue. `stop_hook_active` still bounds
  intra-turn looping, and the per-file content hash still makes the
  review -> fix -> re-edit loop converge. The hook writes the prompt; the agent
  runs the review.
- **Authoring reminders** (`slop_remind.rb`, PreToolUse) surface `cf:ai-slop` when a
  Bash command is about to write a commit message, branch name, or PR title/body,
  so the rubric applies to authored text, not just file contents.

### `auto:` keys

| Key | Meaning |
|---|---|
| `extensions` | File extensions (no dot) that trigger per-edit surfacing |
| `basenames` | Exact filenames that trigger surfacing (e.g. `Rakefile`) |
| `detect` | Glob markers, relative to project root, that mark the skill active at SessionStart |
| `all_code` | `true` = matches every code file via the central extension list (used by `cf:refactoring`) |
| `all_files` | `true` = matches every edited file, code or prose (used by `cf:ai-slop`) |

## CI diff-grep checks

Most skills' "CI enforcement" section ships a one-line idiom a downstream repo
pastes into its own CI: diff the PR's changed files down to a pathspec, then
grep the result for a forbidden pattern. The old form piped `git diff` into
`xargs -I{} git grep`, which is fail-open: `xargs` runs zero times on an empty
input, so the check exits 0 (pass) instead of reporting that it never grepped
anything, and a bare `git grep` with no file arguments silently scans the
whole repository rather than the diff. The canonical form below is fail-closed
instead: every step that cannot produce a trustworthy answer fails the check
rather than passing it.

<!-- CI-DIFF-GREP-IDIOM-START -->
```bash
# CI diff-grep idiom: fails closed. One copy here; each skill's one-liner is
# this same shape, inlined and specialized with its own pathspecs and pattern.
#
# Resolve the base ref explicitly and fail if it cannot be resolved (an
# absent origin/HEAD, a missing BASE_REF override, or a shallow clone without
# the commit) instead of letting an unresolved ref silently diff against
# nothing.
base=$(git rev-parse --verify --quiet "${BASE_REF:-origin/HEAD}^{commit}") &&
# Collect the changed-file list into a temp file so git diff's own exit
# status survives (a process substitution would need bash 4.4's `wait -n`,
# and macOS still ships bash 3.2).
l=$(mktemp) &&
trap 'rm -f "$l"' EXIT &&
# -z plus a NUL-delimited read handles any filename, including ones with
# spaces or newlines, on bash 3.2. --no-renames keeps a rename-plus-edit from
# hiding a changed line under its old name. --diff-filter=AM scopes to
# added/modified files. --merge-base scopes the diff to the PR's actual
# changes (not everything that happened on the base branch since) and errors
# on a shallow clone instead of silently under- or over-matching, so CI needs
# actions/checkout with fetch-depth: 0.
git diff -z --name-only --no-renames --diff-filter=AM --merge-base "$base" -- __PATHSPECS__ >"$l" &&
# Read the NUL-delimited list into an array (requires bash, not POSIX sh).
f=() && while IFS= read -r -d "" p; do f+=("$p"); done <"$l" &&
# An empty file list is a pass (nothing in scope to flag), but git grep with
# no path arguments scans the whole repo, so the empty case must be handled
# explicitly rather than falling through to a bare git grep.
{ [ ${#f[@]} -eq 0 ] || {
    # GIT_LITERAL_PATHSPECS=1 makes every array entry a literal filename, not
    # a pathspec pattern, so a filename that happens to look like a glob
    # cannot change what gets grepped.
    # git grep's exit status: 0 = match found, 1 = no match, 2+ = error (bad
    # pattern, I/O failure). Only 1 is a pass; 0 and 2+ both fail the check.
    # The status is captured through `|| s=$?` so a clean grep's exit 1 does
    # not abort a runner that enables errexit (GitHub Actions runs bash -e).
    s=0
    GIT_LITERAL_PATHSPECS=1 git grep -nP "__PAT__" -- "${f[@]}" || s=$?
    [ $s -eq 1 ]
  };
}
```
<!-- CI-DIFF-GREP-IDIOM-END -->

`BASE_REF` overrides the default `origin/HEAD` (set it, or run
`git remote set-head origin -a`, when CI has no symbolic HEAD for origin).

Site 7 (`skills/pdf-rendering/SKILL.md`) chains two `git grep` passes over the
same file list instead of one: stage one narrows to files matching one
pattern (`-l`, exit 0 or 1 both acceptable, 2+ fails), stage two re-greps only
that narrowed list for a second pattern (`-L`, lists files *lacking* a match,
which exits 0 whenever it lists anything, so the check judges the list's
emptiness, not just the exit status).
