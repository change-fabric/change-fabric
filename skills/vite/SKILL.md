---
name: pst:vite
description: Vite boring-build rubric. Auto-applied by the pst shim when the Vite config changes; also invocable directly.
auto:
  basenames: [vite.config.ts, vite.config.js, vite.config.mjs, vite.config.mts, vite.config.cjs]
  detect: ["vite.config.*"]
---

# Vite Cheat Sheet

Source: Vite Docs

Question: Is dev and build behavior simple, fast, and production-correct?

Favor:
- Vite defaults
- minimal config
- official plugins when possible
- `import.meta.env`
- `VITE_` only for client-exposed vars
- clear mode/env boundaries
- production build verification

Avoid:
- Webpack-era cargo culting
- excessive plugins
- unexplained aliases
- expecting build-time env to change at runtime
- secrets in `VITE_*`
- ESLint disables
- ignored build warnings

CI:
- `vite build`
- `tsc --noEmit`
- lint max warnings = 0

Agent protocol:
1. Prefer defaults.
2. Minimize config.
3. Validate env exposure.
4. Preserve production behavior.
