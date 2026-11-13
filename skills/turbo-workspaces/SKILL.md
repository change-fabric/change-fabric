---
name: cf:turbo-workspaces
group: rubrics
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
- `base=$(git rev-parse --verify --quiet "${BASE_REF:-origin/HEAD}^{commit}") && l=$(mktemp) && trap 'rm -f "$l"' EXIT && git diff -z --name-only --no-renames --diff-filter=AM --merge-base "$base" -- 'apps/**' 'packages/**' >"$l" && f=() && while IFS= read -r -d "" p; do f+=("$p"); done <"$l" && { [ ${#f[@]} -eq 0 ] || { s=0; GIT_LITERAL_PATHSPECS=1 git grep -nP "(\\.\\./){2,}(apps|packages)/" -- "${f[@]}" || s=$?; [ $s -eq 1 ]; }; }` (see skills/README.md, CI diff-grep checks)

pnpm workspaces:
- `node_modules` is symlinks into the root `.pnpm` store. A container step mounts the workspace root, never one package, or the links dangle.
- Tailwind v4 source detection does not follow workspace links. A package that styles another package's markup lists it with an explicit `@source`.
- Detect the package manager from the root lockfile (`pnpm-lock.yaml`, `yarn.lock`, `package-lock.json`) and run its own `run <task>`.

Design kit packages (a cf design target's `kit`, for example `packages/design-kit`):
- The kit depends on app source, never the reverse. No app imports the kit.
- `"private": true`, and no deployed app depends on it, so deploy filters exclude it.
- `build` and `check` are workspace scripts turbo runs: `build` declares `outputs: ["dist/**"]`; `check` depends on `build` and is not cached.

Agent protocol:
1. Keep package boundaries explicit.
2. Move orchestration into `turbo.json`.
3. Declare cache inputs and outputs before tuning.
4. Preserve behavior.
