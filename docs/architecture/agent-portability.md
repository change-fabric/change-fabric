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
