---
name: cf:react
group: rubrics
review: true
description: React review-time rubric for derived state and effects. Applied in the stage 2 review; also invocable directly.
auto:
  min_level: strict
  extensions: [jsx, tsx]
---

# React

- No effects for derived data: compute it during render.
- No state copied from props.

Hooks rules and exhaustive deps are enforced by `eslint-plugin-react-hooks` in the stage 1 review gate.
