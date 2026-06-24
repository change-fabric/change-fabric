# Skills

Each subdirectory is a Claude Code skill (`SKILL.md` with YAML frontmatter).
`install.rb` symlinks every one into `~/.claude/skills/`, so they are all
invocable directly (e.g. `/refactoring`).

## Auto-firing skills

A skill becomes **auto-firing** by adding an `auto:` block to its frontmatter.
The pst shim then surfaces it without anyone invoking it, via three mechanisms:

- **Per-edit routing** (`skill_inject.rb`, PostToolUse) is deterministic
  file-type matching. On every edit whose path matches, the skill's body is
  injected once per session. This is "runs on every Ruby change, no matter
  what" - it does not depend on project detection.
- **Project fingerprint** (`skill_detect.rb`, SessionStart) is a deterministic
  marker-file scan that announces which skills apply, once per session. Project
  type is a file-presence question (`Gemfile`, `*.gemspec`), so it needs no LLM.
- **Review** runs a model against the changed code. As you edit, `skill_inject.rb`
  queues every changed file that matches a `review: true` skill. When the turn
  ends, `skill_review.rb` (Stop hook) drains that queue and blocks once, handing
  the agent a fixed prompt - the skill's principles plus the changed file list -
  to run a haiku background-agent review. Draining the queue and honoring
  `stop_hook_active` keep it to one block per batch. The hook writes the prompt;
  the agent runs the review.

### `auto:` keys

| Key | Meaning |
|---|---|
| `extensions` | File extensions (no dot) that trigger per-edit surfacing |
| `basenames` | Exact filenames that trigger surfacing (e.g. `Rakefile`) |
| `detect` | Glob markers, relative to project root, that mark the skill active at SessionStart |
| `universal` | `true` = active in every project (used by `refactoring`) |
| `review` | `true` = also request a haiku diff review on matching changes |

Skills with no `auto:` block (like `pst`) are plain user-invocable skills and
are never surfaced automatically.
