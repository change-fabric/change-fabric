---
name: cf:turbo-workspaces
description: Turborepo and npm workspaces monorepo wiring. Auto-applied by the cf shim on every workspace or turbo change; also invocable directly.
auto:
  basenames: [turbo.json, package.json]
  require:
    - "**/turbo.json"
  detect: [turbo.json, package.json]
---

# Turborepo and npm Workspaces Cheat Sheet

Source: Turborepo task and caching docs + npm workspaces docs

Question: Can tasks run from declared package boundaries and cache correctly?

Favor:
- Declare every package in root `workspaces`.
- Import other packages by workspace package name.
- Put shared task names in `turbo.json`.
- Use `dependsOn: ["^build"]` when consuming built artifacts.
- Declare `outputs` for cacheable build tasks.
- Mark dev servers `persistent: true` and `cache: false`.
- Keep package scripts thin; let turbo orchestrate.

Forbid by default:
- Cross-package relative imports into another package source tree.
- Per-package lockfiles.
- Hidden build outputs outside declared `outputs`.
- Running package-local installs in CI.
- Circular package dependencies.

CI:
- `turbo run lint build test`
- `npm ls --workspaces`
- `out=$(git diff --name-only --diff-filter=AM origin/HEAD -- 'apps/**' 'packages/**' | xargs -I{} git grep -nP "(\\.\\./){2,}(apps|packages)/" -- {}); [ -z "$out" ]`

Agent protocol:
1. Keep package boundaries explicit.
2. Move orchestration into `turbo.json`.
3. Declare cache inputs and outputs before tuning.
4. Preserve behavior.
