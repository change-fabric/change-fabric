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
