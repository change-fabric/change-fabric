# skills

Canonical source for Patrick's system-wide Claude Code skills and hooks. What's installed is what's here.

## Rules

- Hooks fail silent: parse stdin via `HookEvent.read`, never crash.
- `install.rb` makes the live install match this repo. Re-run after pulling.
- Bump `VERSION` (semver) for release-worthy changes; none for CI-only.
- Squash merge. Patrick merges every PR manually, do not merge unless told. No em-dashes in commits.
