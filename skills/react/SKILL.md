---
name: pst:react
description: React predictable-UI rubric. Auto-applied by the pst shim on every React component change; also invocable directly.
auto:
  extensions: [jsx, tsx]
---

# React Cheat Sheet

Source: React Docs + eslint-plugin-react-hooks

Question: Is UI derived predictably from props and state?

Favor:
- pure components
- immutable props/state
- derived values during render
- local state when sufficient
- composition
- semantic accessible markup
- explicit loading/error/empty states
- effects only for external systems

Avoid:
- mutating props/state
- state copied from props
- effects for derived data
- hidden side effects in render
- unstable keys
- premature memoization
- ESLint disables

CI:
- React hooks lint passes
- lint max warnings = 0

Agent protocol:
1. Keep render pure.
2. Minimize state.
3. Remove unnecessary effects.
4. Preserve visible behavior.
