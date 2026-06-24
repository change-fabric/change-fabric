---
name: pst:typescript
description: TypeScript strict-safety rubric. Auto-applied by the pst shim on every TypeScript change; also invocable directly.
auto:
  extensions: [ts, tsx, mts, cts]
  detect: [tsconfig.json]
---

# TypeScript Cheat Sheet

Source: TypeScript Handbook + TSConfig Reference

Question: Are invalid states hard to represent?

Favor:
- `strict: true`
- `unknown` over `any`
- narrowing before use
- discriminated unions
- exhaustive checks
- precise domain types
- `satisfies` for checked literals
- runtime validation at I/O boundaries

Forbid by default:
- `as any`
- implicit `any`
- unsafe assertions
- non-null `!`
- `@ts-ignore`
- ESLint disables

CI:
- `tsc --noEmit`
- lint max warnings = 0

Agent protocol:
1. Remove unsafe escapes.
2. Model states explicitly.
3. Narrow external data.
4. Preserve behavior.
