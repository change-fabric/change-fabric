# Skills

Each subdirectory is a Claude Code skill (`SKILL.md` with YAML frontmatter).
`install.rb` symlinks every one into `~/.claude/skills/`, so they are all
invocable directly (e.g. `/refactoring`).

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
- **Review** runs a model against the changed code. Whether a skill reviews is a
  convention, not a flag: `all_files` skills surface their body only, while
  code-oriented skills (`all_code` or explicit `extensions`) are reviewed. As you
  edit, `skill_inject.rb` queues every changed file a reviewed skill matches. When
  the turn ends, `skill_review.rb` (Stop hook) drains that queue and blocks once,
  handing the agent a fixed prompt - the skill's principles plus the changed file
  list - to run a haiku background-agent review. Draining the queue and honoring
  `stop_hook_active` keep it to one block per batch; a per-file content hash makes
  the review -> fix -> re-edit loop converge. The hook writes the prompt; the agent
  runs the review.
- **Authoring reminders** (`slop_remind.rb`, PreToolUse) surface `ai-slop` when a
  Bash command is about to write a commit message, branch name, or PR title/body,
  so the rubric applies to authored text, not just file contents.

### `auto:` keys

| Key | Meaning |
|---|---|
| `extensions` | File extensions (no dot) that trigger per-edit surfacing |
| `basenames` | Exact filenames that trigger surfacing (e.g. `Rakefile`) |
| `detect` | Glob markers, relative to project root, that mark the skill active at SessionStart |
| `all_code` | `true` = matches every code file via the central extension list (used by `refactoring`) |
| `all_files` | `true` = matches every edited file, code or prose (used by `ai-slop`) |

Skills with no `auto:` block (like `pst`) are plain user-invocable skills and
are never surfaced automatically.
