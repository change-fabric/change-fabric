# skills

Canonical source for system-wide Claude Code skills and hooks. What's installed is what's here.

## Rules

- Hooks fail silent: parse stdin via `HookEvent.read`, never crash.
- `install.rb` makes the live install match this repo. Re-run after pulling.
- Bump `VERSION` (semver) for release-worthy changes; none for CI-only.
- Squash merge. The maintainer merges every PR manually, do not merge unless told.
- No AI-slop glyphs in any authored output (commits, PRs, comments, prose, code): no em-dash, bullet, ellipsis, or smart quotes. `glyph_guard.rb` denies them at PreToolUse; `PST_ALLOW_GLYPH=1` is the escape hatch.
- Project services run in containers, never host daemons. `docker_doctrine_guard.rb` denies a Bash command that starts a service as a Homebrew or host daemon (`brew install/services` for a known service, a bare `redis-server`/`caddy run`, etc.) at PreToolUse; `PST_ALLOW_HOSTDAEMON=1` is the escape hatch. `doctrine_digest.rb` states the session-global tenets (this plus the slop rule) once at SessionStart. The full rubric is `skills/docker/SKILL.md`.
- A push or PR is gated on a completed design review of the files changed this session; `review_gate.rb` denies at PreToolUse until released. Run the review it hands back, then `ruby ~/.claude/pst/bin/review_ack.rb <session_id>` to record the verdict and release the gate. The round cap (5) is the escape valve.
- A `gh pr merge` into a repo's protected branch (staging/production, per that repo's root `CHANGE.md`) is gated on a passing comprehensive `pst:change` run recorded for the PR's head SHA, and on the repo's own admin-bypass policy; `change_merge_guard.rb` denies at PreToolUse. Only a repo carrying a `CHANGE.md` is governed. `PST_ALLOW_UNGATED_MERGE=1` is the escape hatch. The `pst:change` platform (one file per repo, the root `CHANGE.md`, whose frontmatter carries both `change_config:` and `change_policy:`; four dockerized audit lanes) is `skills/change/SKILL.md`.
