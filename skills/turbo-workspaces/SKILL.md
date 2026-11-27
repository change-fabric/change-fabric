---
name: cf:turbo-workspaces
group: rubrics
review: true
description: Turborepo and pnpm or npm workspaces house notes. Auto-applied on turbo.json projects; also invocable directly.
auto:
  min_level: lean
  basenames: [turbo.json, package.json]
  require:
    - "**/turbo.json"
  detect: [turbo.json, package.json]
---

# Turborepo and workspaces

- Import other packages by workspace name, never by a relative path into another package's source. One lockfile at the root; no circular package dependencies.
- Shared tasks live in `turbo.json`. Declare `outputs` on cacheable tasks, `dependsOn: ["^build"]` when consuming built artifacts, and `persistent: true` with `cache: false` on dev servers.
- pnpm: `node_modules` is symlinks into the root store, so a container step mounts the workspace root, never one package. Tailwind v4 does not follow workspace links; list another package's markup with an explicit `@source`.
- Detect the package manager from the root lockfile and run its own `run <task>`.
- A design kit package is `"private": true`, depends on app source and never the reverse, and no deployed app depends on it.
