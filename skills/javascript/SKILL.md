---
name: pst:javascript
description: Modern JavaScript (ESM/JSX) design and safety. Auto-applied by the pst shim on every JavaScript change; also invocable directly.
auto:
  extensions: [js, mjs, cjs, jsx]
  detect: [package.json, "eslint.config.*", ".eslintrc*", jsconfig.json]
---

# JavaScript Cheat Sheet

Source: *You Don't Know JS* (Kyle Simpson), MDN JavaScript Guide, ECMAScript Language Specification, ESLint

Question: Does this code follow JavaScript's actual semantics rather than relying on accidental behavior?

Favor:
- Prefer `const`; use `let` only when reassignment models the domain.
- Prefer lexical scope and small, composable functions.
- Trace `this` from the call site; use arrow functions only for lexical `this`.
- Prefer composition and prototype delegation over class hierarchies.
- Know runtime types; make coercion intentional.
- Validate external input at I/O boundaries.
- Keep modules small with explicit imports and exports.
- Express asynchronous flows with Promises and `async`/`await`.
- Optimize first for readability and correct semantics.

Forbid by default:
- `var`, `eval`, `with`, or implicit globals.
- `new Function()` or monkey-patching built-in prototypes.
- Hidden mutation across module boundaries.
- Shared mutable module state without clear ownership.
- Unnecessary nested callbacks.
- Implicit coercion that obscures intent.
- Disabling ESLint rules to silence violations.

CI:
- npx --no-install eslint . --max-warnings=0
- npm test

Agent protocol:
1. Reason from JavaScript semantics before changing code.
2. Verify scope, closures, `this`, runtime types, and async behavior.
3. Remove hidden state, unnecessary mutation, and accidental complexity.
4. Preserve behavior.
