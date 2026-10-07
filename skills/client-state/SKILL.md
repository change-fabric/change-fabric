---
name: cf:client-state
description: Redux Toolkit and TanStack Query state management. Auto-applied by the cf shim on every client-state change; also invocable directly.
auto:
  extensions: [js, jsx]
  require:
    - dep: ["@reduxjs/toolkit", react-redux, redux, "@tanstack/react-query"]
  detect: ["**/*slice.js", "**/*store.js", "**/*query*.js", "**/*api*.js"]
---

# Client State Management Cheat Sheet

Source: Redux Style Guide + Redux Toolkit usage docs + TanStack Query docs

Question: Is server state in Query and client state in Redux with one write path each?

Favor:
- Put server data in TanStack Query.
- Put UI workflow and cross-screen client state in Redux Toolkit.
- Use array query keys only.
- Invalidate or update queries from mutation success paths.
- Keep Redux state serializable.
- Derive with selectors; keep writes in reducers and mutations.
- Keep one canonical owner per datum.

Forbid by default:
- Mirroring query results into Redux state.
- Query keys built from functions, class instances, or unstable objects.
- Non-serializable Redux state or actions.
- Fetching server data in `useEffect` plus `dispatch` when a query fits.
- Global loading flags for query-owned requests.

CI:
- `npx --no-install eslint . --max-warnings 0`
- `vitest run`
- `base=$(git rev-parse --verify --quiet "${BASE_REF:-origin/HEAD}^{commit}") && l=$(mktemp) && trap 'rm -f "$l"' EXIT && git diff -z --name-only --no-renames --diff-filter=AM --merge-base "$base" -- '*.js' '*.jsx' >"$l" && f=() && while IFS= read -r -d "" p; do f+=("$p"); done <"$l" && { [ ${#f[@]} -eq 0 ] || { s=0; GIT_LITERAL_PATHSPECS=1 git grep -nP "queryKey:\\s*['\\\"]|queryKey:.*\\bnew (Map|Set|Date)\\(|useEffect\\(.*dispatch\\(" -- "${f[@]}" || s=$?; [ $s -eq 1 ]; }; }` (see skills/README.md, CI diff-grep checks)

Agent protocol:
1. Decide whether each datum is server or client state.
2. Remove duplicated ownership.
3. Tighten query keys, invalidation, and serializability.
4. Preserve behavior.
