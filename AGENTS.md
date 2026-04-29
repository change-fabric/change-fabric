# Skills Repository

Reusable workflow skills for Claude Code, OpenAI Codex, and Pi Coding Agent.

## Compatibility

- Source skills live in `skills/<name>/SKILL.md`.
- Claude Code installs them as slash-command symlinks in `~/.claude/commands/`.
- OpenAI Codex installs them as skill directory symlinks in `~/.codex/skills/`.
- Pi installs portable wrapper skills in `~/.pi/agent/skills/` with Agent Skills-safe lower-kebab names.
  - Example: `pst:push` becomes `/skill:pst-push` in Pi.
- When adding a new skill, update the `SKILLS` array in `install.sh` and the README.

## Development

- Keep skill frontmatter valid Agent Skills YAML where possible.
- Prefer harness-neutral instructions. If a workflow depends on a harness-specific tool, include a fallback path for other harnesses.
- Do not commit local secrets such as `.env`.
