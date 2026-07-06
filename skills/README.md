# Skills

Each subdirectory is a Claude Code skill (`SKILL.md` with YAML frontmatter).
`install.rb` symlinks every one into `~/.claude/skills/`, so they are all
invocable directly (e.g. `/pst:refactoring`). Re-running it also prunes its own
stale links: a symlink into this repo's `skills/` with no matching source (a
renamed or deleted skill) is removed, while real dirs and links into other
repos are left alone.

Directory names stay plain and portable (no colons committed to git). The
`pst:` namespace lives only in each skill's frontmatter `name:`, which is what
`SkillRegistry` and Claude Code resolve by; `install.rb` names the symlink from
that single source. `pst` itself is the namespace root and stays unprefixed.

Skills fall into two kinds, by whether they carry an `auto:` block.

## Command skills (manually invoked)

A skill with no `auto:` block is a command: it runs only when you invoke it, and
the hooks never surface it. These are verbs the agent performs on demand.

| Skill | Does |
|---|---|
| `pst` | Sets and enforces the session merge mode. |
| `pst:refactor` | Refactors a scope you name (PR, branch, repo, file, or glob), routing each file through the auto-firing skills that cover it. |
| `pst:code-review` | Reviews a scope you name (PR, branch, files, or a feature description), verifies each candidate finding in an isolated worktree, and posts only what survives. |
| `pst:ctx` | Captures, recalls, and lists durable project context in the shim-owned .ctx store. |
| `pst:prune` | Post-merge cleanup: fast-forwards the trunk and prunes merged branches and worktrees, local and remote, asking before it discards unmerged work or deletes any remote branch. |

`pst:refactor` reuses the routing below by shelling out to `skill_route.rb`
(`scripts/skill_route.rb`, copied to the shim bin but not wired as a hook): it
maps a changeset's files to the skills that match, so a one-shot refactor
applies the same rubrics the per-edit hooks would.

## Auto-firing skills

A skill becomes **auto-firing** by adding an `auto:` block to its frontmatter.
The pst shim then surfaces it without anyone invoking it:

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
  that merely look like code), while `all_files` skills (`pst:ai-slop`) review
  every changed file, prose and documentation included. As you edit,
  `skill_inject.rb` queues every changed file each matching skill covers. When
  the turn ends, `skill_review.rb` (Stop hook) drains that queue and blocks once,
  handing the agent a fixed prompt - the skill's principles plus the changed file
  list - to run a haiku background-agent review. Draining the queue and honoring
  `stop_hook_active` keep it to one block per batch; a per-file content hash makes
  the review -> fix -> re-edit loop converge. The hook writes the prompt; the agent
  runs the review.
- **Authoring reminders** (`slop_remind.rb`, PreToolUse) surface `pst:ai-slop` when a
  Bash command is about to write a commit message, branch name, or PR title/body,
  so the rubric applies to authored text, not just file contents.

### `auto:` keys

| Key | Meaning |
|---|---|
| `extensions` | File extensions (no dot) that trigger per-edit surfacing |
| `basenames` | Exact filenames that trigger surfacing (e.g. `Rakefile`) |
| `detect` | Glob markers, relative to project root, that mark the skill active at SessionStart |
| `all_code` | `true` = matches every code file via the central extension list (used by `pst:refactoring`) |
| `all_files` | `true` = matches every edited file, code or prose (used by `pst:ai-slop`) |
