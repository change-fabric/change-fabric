---
name: cf:typescript
group: rubrics
review: true
description: TypeScript review-time rubric for modeling states. Applied in the stage 2 review; also invocable directly.
auto:
  min_level: strict
  extensions: [ts, tsx, mts, cts]
  detect: [tsconfig.json]
---

# TypeScript

- Model alternatives as discriminated unions with an exhaustive check, not optional fields that must be set together.
- Validate external data at the I/O boundary instead of asserting its type.

`strict`, `any`, non-null assertions, and `@ts-ignore` are enforced by `tsc` and typescript-eslint in the stage 1 review gate.
