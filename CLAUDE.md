# skills

Canonical source for Patrick's system-wide Claude Code skills and hooks. What's installed is what's here.

## Rules

- Hooks fail silent: parse stdin via `HookEvent.read`, never crash.
- `install.rb` makes the live install match this repo. Re-run after pulling.
- Bump `VERSION` (semver) for release-worthy changes; none for CI-only.
- Squash merge. Patrick merges every PR manually, do not merge unless told.
- No AI-slop glyphs in any authored output (commits, PRs, comments, prose, code): no em-dash, bullet, ellipsis, or smart quotes. `glyph_guard.rb` denies them at PreToolUse; `PST_ALLOW_GLYPH=1` is the escape hatch.
- A push or PR is gated on a completed design review of the files changed this session; `review_gate.rb` denies at PreToolUse until released. Run the review it hands back, then `ruby ~/.claude/pst/bin/review_ack.rb <session_id>` to record the verdict and release the gate. The round cap (5) is the escape valve.
