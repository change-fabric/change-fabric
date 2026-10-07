---
name: cf:js-testing
description: Vitest, Jest, Cypress, and Testing Library tests. Auto-applied by the cf shim on every JS test change; also invocable directly.
auto:
  paths:
    - "**/*.test.{js,jsx,mjs,cjs}"
    - "**/*.spec.{js,jsx,mjs,cjs}"
    - "**/*.cy.{js,jsx}"
    - "**/{vitest,jest,cypress}.config.*"
  require:
    - dep: [vitest, jest, mocha, cypress, "@testing-library/react"]
  detect: ["**/*.test.js", "**/*.spec.js", "**/*.cy.js", "vitest.config.*", "jest.config.*", "cypress.config.*"]
---

# JavaScript Testing Cheat Sheet

Source: Vitest docs + Jest CLI docs + Cypress Best Practices + Testing Library queries docs

Question: Do tests fail only on behavior regressions, not timing or environment luck?

Favor:
- Put unit logic in Vitest or Jest; browser flows in Cypress.
- Query UI by role, label, or text.
- Mock or intercept network with stable fixtures.
- Use fake timers for clock-driven behavior.
- Seed explicit state per test.
- Assert visible behavior, not implementation details.
- Keep coverage thresholds at package or changed-code scope.

Forbid by default:
- Committed `.only` or `.skip`.
- Arbitrary sleeps like `cy.wait(500)` or bare `setTimeout`.
- Snapshotting large markup trees by default.
- Real network calls to third-party services.
- Shared mutable globals between tests.

CI:
- `vitest run --coverage`
- `jest --ci --coverage`
- `cypress run`
- `base=$(git rev-parse --verify --quiet "${BASE_REF:-origin/HEAD}^{commit}") && l=$(mktemp) && trap 'rm -f "$l"' EXIT && git diff -z --name-only --no-renames --diff-filter=AM --merge-base "$base" -- '*.test.js' '*.spec.js' '*.cy.js' 'cypress/**' >"$l" && f=() && while IFS= read -r -d "" p; do f+=("$p"); done <"$l" && { [ ${#f[@]} -eq 0 ] || { s=0; GIT_LITERAL_PATHSPECS=1 git grep -nE "\\.(only|skip)\\(|cy\\.wait\\([0-9]+" -- "${f[@]}" || s=$?; [ $s -eq 1 ]; }; }` (see skills/README.md, CI diff-grep checks)

Agent protocol:
1. Pick the smallest runner that matches the behavior.
2. Remove time and network flake first.
3. Tighten assertions around user-visible outcomes.
4. Preserve behavior.
