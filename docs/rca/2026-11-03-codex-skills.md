# Codex mode skill discovery failure

Date: 2026-11-03

## Impact and evidence

An installed toolkit did not expose merge-ready mode in Codex. Entering
`/cf:merge-ready` produced an unrecognized-command error. Inspection found
CF skills under Claude, OpenCode, and Copilot locations, but no CF skills in
the user's Codex discovery directory.

The installer at base commit `4a3982f` had no Codex destination or mirror
step. Its legacy Pi pruner also listed `~/.agents/skills` as obsolete Pi
storage and could remove skills with matching CF manifest names there.
That cleanup is a code-supported risk; it was not proven to have deleted
skills on the affected device.

## Root cause

There was no implemented Codex port in the installer. The reported expectation
of cross-host compatibility exceeded the implementation. Tests covered installed files
for Claude, Pi, OpenCode, and Copilot, but had no Codex discovery contract.

Three host-specific contracts were missing: discovery location, invocation
syntax, and lifecycle semantics. Claude's colon-namespaced slash commands
are not registered as Codex slash commands. Copying the original mode files
alone would also be incorrect: they say a Claude hook has already persisted
mode state, although this installer registers no Codex hooks.

## Fix

The installer now generates owned copies under `~/.agents/skills`, using
portable names such as `cf-merge-ready`, retaining supporting resources,
and translating command references to Codex skill mentions. It retains only
portable name and description metadata in Codex manifests. The existing
ownership marker scopes refresh and deletion to generated copies, preserving
unmanaged skills, including name collisions. The legacy Pi pruner no longer
owns the Codex discovery directory.

Seven mode skills supply explicit Codex bodies in `reference/codex.md`.
These instructions set conversation state, carry it into compaction summaries,
and describe the intended workflow without claiming hooks ran or that state
was persisted. Canonical Claude bodies remain unchanged.

Use `$cf-merge-ready` or `/skills` in Codex. The same workflow name does not
imply the same command syntax or enforcement across hosts. This hotfix does
not implement Codex lifecycle hooks, automatic persistence, per-turn reminders,
or command guards. Other mirrored skills remain workflow guidance and may
describe Claude-only hook behavior; a generated notice states that boundary.

## Systemic prevention

Installer tests now cover every skill's Codex discovery path, valid portable
metadata, resource retention, all mode overrides, repeat installation,
refresh of stale generated content, removal of obsolete owned skills, and
preservation of unmanaged skills. Command translation must preserve hook
filesystem paths. Existing Pi, OpenCode, Copilot, and Claude tests remain
part of the same suite.

Future host support must establish discovery, invocation, and lifecycle
behavior separately. A copied manifest is not proof of a working integration.
Claims of guard or persistence parity require a host-specific adapter and
tests before documentation presents them as supported. After installation,
check the host's skill selector and invoke a mode in a new session; disk
layout tests alone do not prove model behavior.

## Verification and remaining limits

The installer suite passed 43 tests with 713 assertions. Changed-file RuboCop
passed. A separate local smoke check generated mirrors in a temporary Git
repository and queried the installed Codex app-server's `skills/list` endpoint:
all 62 skills were discovered and enabled, including `cf-merge-ready`, with
no CF parsing errors. It did not start a model turn or prove behavioral adherence.

Run `bundle exec ruby -Itest test/install_test.rb` and
`bundle exec rubocop install.rb test/install_test.rb`. Re-run `ruby install.rb`,
then select `cf-merge-ready` through Codex's `/skills` picker. Verify the
agent acknowledges merge-ready and stops before merging. This manual
behavioral check is distinct from automated installation checks.

The separate startup hang was an unbounded skill-detection scan from a large
working directory. It is addressed independently in PR #290; this PR does
not depend on that change. The local shell's `codexo` alias was also using
only `--dangerously-bypass-hook-trust`. That flag controls hook trust, not
execution approvals or sandboxing. Its local correction is not part of this
repository change, and CF merge modes never change Codex's permission policy.

## Sources

- [Official skill discovery and invocation documentation](https://learn.chatgpt.com/docs/build-skills)
- Local installed `codex --help`, inspected 2026-11-03, for distinct hook trust
  and approval/sandbox flags.
- `install.rb` and `test/install_test.rb` at base commit `4a3982f`.
