# Agent portability

Parent: https://github.com/change-fabric/change-fabric/issues/297

CF has one workflow intent and explicit adapters for Claude, Codex, Copilot,
OpenCode, and Pi. `workflows/modes` owns mode contracts. `SkillCompiler`
renders invocation references and metadata for every installed host, including
Claude. Older skill prose remains supported through a narrowly scoped legacy
command-reference parser; hook descriptions in that prose refer only to Claude.
The generated host contract makes that boundary explicit.

New shared prose uses `{{skill:plan}}` references. Resources are rendered too,
so following a reference does not reintroduce another host's invocation syntax.
Executable scripts and filesystem paths are copied unchanged. Host-specific
behavior belongs in adapters, not claims that a hook must already have run.

Claude's discovery links now point to managed generated copies. Pi has its own
portable copies rather than reading Claude's generated body. Original skill
sources remain the registry for automatic rubric detection. Installation owns
only marked output and links into CF sources; user-owned collisions survive.

The six layers are shared generation, runtime/state, capabilities, native
adapters, behavioral contracts, and doctor/lifecycle maintenance. Discovery,
adapter conformance, and real model behavior are separate verification levels.

## Shared runtime protocol

`ruby scripts/cf_runtime.rb` consumes one JSON request on stdin and returns one
JSON response. Protocol version 1 requires `host`, absolute `project`, stable
`session_id`, and `event`. Events: `session.start`, `context`, `mode.set`,
`availability.set`, `tool.before`, and `tool.after`. Set requests carry `mode`
or `availability`; tool requests carry `{name, input}`. The adapter maps native
tools to `shell`, `git.push`, `pr.create`, or `pr.merge` where known.

State lives at `~/.local/state/change-fabric` (or `CF_STATE_HOME`), partitioned
by host, canonical repository root, and hashed session identity. Subdirectories
share a repository; distinct worktrees remain independent. Resume reuses the
identity. Child sessions explicitly bind a parent, inherit its current mode,
and may override it without mutating the parent. Bindings cannot be changed or
made cyclic. Session IDs never become path components. Atomic writes under a
lock preserve concurrent field updates. State files have mode 0600.

Claude legacy merge-mode files are read only when no neutral mode exists.
The runtime never imports another host's legacy file or removes old state.
Legacy hook migration is handled by the native adapter installation layer.
The policy uses the existing advisory shell classifier and additionally handles
structured Git/PR actions. Unknown tools are outside that classifier's coverage;
this is not a sandbox or a substitute for repository protections.

## Capability evidence

`config/host_capabilities.json` is a versioned host/surface registry. Each entry
names its documentation source, date, reference versions, exact tested versions,
and feature-level evidence. Exact versions are deliberately conservative: passing
against one release does not establish compatibility with a future release.
Reference versions identify locally observed binaries, not successful model runs.

`HostCapabilities#resolve` returns both documented features and effective tested
support. Missing or unknown versions remain unverified; unknown surfaces cannot
inherit CLI hooks. Desktop, cloud, editor, and RPC profiles start as instructions
only until their native integration is verified. Adapter fixture tests and live
model evidence must be recorded independently. No registry entry currently claims
a successful live behavioral run. Native hook support is conditional on host
configuration, trust, and execution-environment access.

## Native adapters

`cf_host_hook.rb` maps Claude/Codex PascalCase and Copilot camelCase payloads
to the same runtime and returns each host's native context/deny shape. Explicit
mode invocations persist before returning context; successful skill-tool loads
also persist modes. Failed loads do not. Native subagent IDs bind child state to
the parent. A missing session ID is an error rather than a shared cwd identity.
Shell input aliases include Codex unified exec. Known GitHub PR tools map to
structured actions. Other tools remain outside command-policy coverage.

The installer wires Claude's mode adapter alongside its existing rubric/review
hooks, writes Codex `hooks.json`, and writes a dedicated Copilot CLI hook file.
Existing unrelated hooks survive. Codex hooks still require the host's feature,
trust review, and environment access; CF never grants itself trust or changes
sandbox permissions. Copilot command prompt hooks can persist a selection but
cannot inject prompt context; startup and successful tool-result hooks provide
context instead. Cloud/editor deployment requires its own configuration.

Pi and OpenCode use the same bounded TypeScript client to invoke the native
adapter. Runtime errors are explicit and policy checks reject on evaluation
failure. Pi has a best-effort review follow-up, not a blocking Stop equivalent.
OpenCode restores mode context through its system transform and compaction
interfaces; those experimental APIs remain version-sensitive. Sessionless Pi
runs use independent random IDs. Existing session files support resume.

Automatic rubric matching reuses the registry and existing review queue with a
host/project/session-derived opaque key. These legacy rubric/review queues still
live under `.claude/cf`; mode and availability state are fully neutral. Moving
all other CF subsystems' data is outside this migration. Hosted tools, arbitrary
API calls, shell indirection, and host timeouts are not a security boundary.

Sources checked on 2026-11-04:
- https://learn.chatgpt.com/docs/hooks
- https://learn.chatgpt.com/docs/build-skills
- https://docs.github.com/en/copilot/reference/hooks-reference
- https://code.claude.com/docs/en/hooks
- https://docs.opencode.ai/docs/plugins/
- Pi's installed `ExtensionAPI` declarations (npm lockfile version).

## Behavioral verification

`bundle exec ruby -Itest test/agent_contract_test.rb` runs one scenario matrix
through all five native wire formats in fresh directories and actual Ruby
subprocesses. It covers all four modes, PR creation/merge, feature/trunk pushes,
resume, child inheritance, malformed payloads, and the reported `/cf:roast`
reference conversion. `npm run test:adapters` additionally loads the actual Pi
and OpenCode TypeScript handlers and calls the Ruby process, including missing
runtime and timeout paths. CI runs both suites for every stacked PR base.
These are deterministic integration checks, not model behavior claims.

An explicit model smoke can be run from the repository:

```
bundle exec ruby test/support/agent_smoke.rb --host codex --output /tmp/cf-smoke.json
```

The runner installs into a temporary HOME, copies local Codex authentication
with mode 0600 for that run, enables hooks only in that temporary config, and
uses read-only execution. It bypasses hook trust only for its generated, vetted
temporary hooks; it does not change live trust or approval settings. Temporary
authentication is removed on completion. The JSON artifact reports the precise
scope, binary version, model output, and persistence evidence. It never points
to a real remote. Other host profiles report `not-run` when isolated auth is not
implemented or their binary is unavailable; they never use the live HOME as a
fallback. `not-run` is not a pass.

On 2026-11-04, Codex CLI 0.166.0 passed explicit `$cf-local-only` activation,
model acknowledgement, and native hook persistence. No live behavior claim is
made for the other four hosts or the other skills. Codex's `/cf:roast` remains
unsupported syntax; use `$cf-roast` or the `/skills` picker.

## Diagnostics and owned installation lifecycle

`cf doctor --host HOST [--json]` reports native invocation, binary version,
installed files, adapter configuration, runtime availability, state root,
dependencies, and version/live evidence. It intentionally reports host discovery
and adapter activation as not probed: reading files cannot prove either.
A foreign `~/.local/bin/cf` is preserved; the repository entry point remains
`ruby scripts/cf_cli.rb`. Runtime context supplies an explicit session-bound
mode command for implicitly loaded mode skills, avoiding cwd-based guessing.

The installer snapshots known output hashes and link targets in
`~/.local/share/change-fabric/installation.json`. Dry-run uninstall lists the
plan; `--apply` removes native/legacy CF hook entries and unchanged managed
files only. User edits, foreign files, state, and backups remain. There is no
recursive directory deletion. Parent-symlink replacement cannot redirect the
manifest's ordinary removal checks outside HOME. External XDG locations are
excluded from the home-scoped removal manifest and require explicit cleanup.
Legacy Claude availability, as well as merge mode, remains a read-only fallback.
