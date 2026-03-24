---
name: pst:react-refactor
description: Extract business logic from React/Next.js components into tested custom hooks — layered on Vercel react-best-practices
argument-hint: "[file-pattern | --all | --branch <name> | --dry-run]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, AskUserQuestion
---

# React Refactor: Business Logic to Hooks + Tests

Extract business logic from React/Next.js components into custom hooks with comprehensive vitest tests. Uses Vercel react-best-practices as the industry baseline, layered with opinionated architecture preferences.

---

## Stage 1 — Input Parsing

<arguments> #$ARGUMENTS </arguments>

**Parse arguments:**

- File glob pattern (e.g., `src/components/Dashboard.tsx`) — refactor specific files
- `--all` — scan entire `src/` for components with extractable business logic
- `--branch <name>` — scope to files changed on the named branch vs the default branch
- `--dry-run` — analysis only, no file modifications, print what would change

**Default behavior (no arguments):** Detect `.tsx` files changed on the current branch vs the default branch:

```bash
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
git diff --name-only "$DEFAULT_BRANCH"...HEAD -- '*.tsx'
```

If no `.tsx` files found on the branch, ask the user via AskUserQuestion what to target.

---

## Stage 2 — External Rules Loading

Load Vercel react-best-practices as the industry baseline. These rules are installed by `install.sh` via the skills CLI (`npx skills add vercel-labs/agent-skills --skill vercel-react-best-practices -g`).

**Resolution order** (first match wins):

1. `~/.claude/skills/vercel-react-best-practices/SKILL.md` — global skills CLI install location
2. `./.claude/skills/vercel-react-best-practices/SKILL.md` — project-local skills CLI install
3. `~/.claude/commands/vercel-react-best-practices.md` — legacy commands directory

The Vercel skill ships with `SKILL.md`, `AGENTS.md`, and a `rules/` directory containing categorized rule files.

**If found:** Read `SKILL.md` and `AGENTS.md` with the `Read` tool. For deeper context, also read files in the `rules/` directory. Internalize these as the baseline layer. Personal override rules (Stage 3) take precedence on any conflict.

**If not found:** Log this warning and proceed with personal rules only:

```
WARNING: Vercel react-best-practices not found.
         Run ./install.sh or: npx -y skills add vercel-labs/agent-skills --skill vercel-react-best-practices -g -y
```

---

## Stage 3 — Personal Override Rules

These 15 rules are **OVERRIDE priority** — they take precedence over any Vercel rule on conflict.

| # | Rule |
|---|------|
| 1 | Business logic MUST live in custom hooks (`use*.ts`), never in component `.tsx` files. Components are for UI composition only. |
| 2 | Custom hooks use `.ts` extension — they contain no JSX, so `.tsx` is unnecessary. |
| 3 | Test files co-located next to their hook: `useMyHook.test.ts` alongside `useMyHook.ts`. |
| 4 | Tests use **vitest** exclusively. No jest. No React Testing Library for pure logic. Only use `renderHook` from `@testing-library/react` when the hook calls React APIs (`useState`, `useEffect`, etc.). Pure functions exported from hook files are tested directly. |
| 5 | **Comprehensive test coverage**: every branch, edge case, error state, boundary value, and statement. Tests should be thorough enough that business logic bugs are caught in hooks, not in integration tests. |
| 6 | **Zero `eslint-disable` comments** in all files (hooks, components, tests). If the linter complains, fix the code or adjust the ESLint config. **NEVER introduce an `eslint-disable` without explicit user approval** — use AskUserQuestion to explain the lint error, the context, and propose alternatives (fix the code, adjust the rule config, or suppress). Default recommendation is to NOT suppress. |
| 7 | `useState`, `useEffect`, and other React hooks used **only in standard patterns**. No workarounds, no hacks, no non-standard invocations that fight the framework. |
| 8 | **Server components by default** in Next.js. Add `'use client'` only when the component genuinely needs client-side interactivity. Do not add it preemptively. |
| 9 | **Named exports only** — no default exports for hooks or components. |
| 10 | **Codify the architecture decision** in the target repo for future LLM runs (see Stage 7). |
| 11 | **Use `next/image` `<Image>` instead of HTML `<img>`** in Next.js projects. Replace `<img>` with `<Image>` from `next/image`, providing required `width`/`height` or `fill` props. Skip if not Next.js. |
| 12 | **ESLint `--max-warnings 0`**: All lint runs MUST pass with zero warnings. Use `--max-warnings 0` flag. Warnings are treated as errors. |
| 13 | **Strict TypeScript — no escape hatches**: No `any` types, no `@ts-ignore`, no `@ts-expect-error`, no `as` type assertions unless truly unavoidable (document why inline). Prefer type guards or generics. |
| 14 | **Prettier compliance**: All created and modified files MUST conform to the project's Prettier configuration. Run Prettier check as part of verification. Skip if Prettier is not configured in the project. |
| 15 | **Minimize `eslint-disable` everywhere** — not just hooks. Applies to component files, test files, and any other file touched during refactoring. See Rule 6 for the mandatory AskUserQuestion workflow. |

---

## Stage 4 — Discovery

For each target `.tsx` file:

1. **Read** the component file
2. **Classify**: Server Component (no `'use client'`) vs Client Component (`'use client'` present)
3. **Identify extractable business logic**:
   - State management logic (multiple `useState` with derived state, reducers)
   - Side effects with business logic (`useEffect` doing more than simple subscriptions)
   - Data transformation, filtering, sorting, mapping
   - Form validation logic
   - API call orchestration and response handling
   - Conditional logic that computes derived values for rendering
4. **Skip** files where:
   - Business logic already lives in hooks (component just calls them)
   - Component is purely presentational (props in, JSX out, no logic)
   - Logic is trivial (single boolean toggle, nothing to extract)

**Print discovery report:**

```
DISCOVERY REPORT
────────────────
Files scanned: {N}
Candidates for refactoring: {M}
Skipped (already clean): {K}

  src/components/Dashboard.tsx — 3 extractable blocks (state mgmt, data transform, API orchestration)
  src/components/UserForm.tsx  — 2 extractable blocks (validation, form submission)
  src/components/Settings.tsx  — SKIP (business logic already in useSettings hook)
```

**If `--dry-run`:** Stop here. Do not modify any files.

---

## Stage 5 — Refactoring

Process each candidate component. **If multiple candidates share a directory or imports, process them sequentially to avoid conflicting edits.** Only parallelize across independent directories.

```
Agent:
  description: "Refactor {ComponentName}: extract business logic to hooks"
```

**Sub-agent workflow per component:**

### 5a. Plan the Extraction

- Identify each block of business logic to extract
- Name the hook: prefer specific names (`useDashboardFilters`, `useUserFormValidation`) over generic ones (`useDashboardLogic`)
- Define the hook's interface: inputs (props/params it needs) and outputs (state, handlers, computed values it returns)
- If a component has multiple unrelated concerns, create multiple hooks

### 5b. Create the Hook File

Create `use{Name}.ts` in the same directory as the component (or in a `hooks/` subdirectory if one already exists in the project convention).

**Hook file rules:**

- `.ts` extension (not `.tsx`)
- Named export: `export function use{Name}(...) { ... }`
- No `eslint-disable` comments
- Standard React hook patterns only
- Pure helper functions exported alongside the hook for direct testing
- Clear TypeScript types for inputs and outputs
- No `any` types — use proper generics or specific types
- No `@ts-ignore` or `@ts-expect-error` — fix the type error instead
- No `as` type assertions unless absolutely necessary (document why if used)

**Example structure:**

```typescript
// useDashboardFilters.ts
import { useState, useMemo } from 'react';

interface DashboardFiltersInput {
  initialData: DashboardItem[];
}

interface DashboardFiltersOutput {
  filteredData: DashboardItem[];
  activeFilter: FilterType;
  setFilter: (filter: FilterType) => void;
  sortOrder: SortOrder;
  setSortOrder: (order: SortOrder) => void;
}

// Pure function — tested directly, no renderHook needed
export function applyFilter(data: DashboardItem[], filter: FilterType): DashboardItem[] {
  // ...
}

// Pure function — tested directly
export function sortData(data: DashboardItem[], order: SortOrder): DashboardItem[] {
  // ...
}

// Hook — uses React state, tested with renderHook
export function useDashboardFilters({ initialData }: DashboardFiltersInput): DashboardFiltersOutput {
  const [activeFilter, setFilter] = useState<FilterType>('all');
  const [sortOrder, setSortOrder] = useState<SortOrder>('desc');

  const filteredData = useMemo(
    () => sortData(applyFilter(initialData, activeFilter), sortOrder),
    [initialData, activeFilter, sortOrder]
  );

  return { filteredData, activeFilter, setFilter, sortOrder, setSortOrder };
}
```

### 5c. Update the Component

Replace inline business logic with hook call(s). The component should now be primarily JSX with hook calls at the top.

- Import the hook(s) with named imports
- Remove extracted logic from the component body
- If the project uses Next.js: replace any HTML `<img>` tags with `<Image>` from `next/image` while editing the component
- Verify the component still compiles (no missing references)

### 5d. Create the Test File

Create `use{Name}.test.ts` co-located with the hook file.

**Test file structure:**

```typescript
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useDashboardFilters, applyFilter, sortData } from './useDashboardFilters';

// Pure function tests — no renderHook needed
describe('applyFilter', () => {
  it('returns all items when filter is "all"', () => { /* ... */ });
  it('filters by category correctly', () => { /* ... */ });
  it('returns empty array for empty input', () => { /* ... */ });
  it('handles unknown filter type gracefully', () => { /* ... */ });
});

describe('sortData', () => {
  it('sorts ascending', () => { /* ... */ });
  it('sorts descending', () => { /* ... */ });
  it('handles empty array', () => { /* ... */ });
  it('handles single item', () => { /* ... */ });
  it('is stable for equal values', () => { /* ... */ });
});

// Hook tests — needs renderHook because of useState
describe('useDashboardFilters', () => {
  it('initializes with default filter and sort', () => { /* ... */ });
  it('updates filtered data when filter changes', () => { /* ... */ });
  it('updates filtered data when sort order changes', () => { /* ... */ });
  it('recomputes when initialData changes', () => { /* ... */ });
});
```

**Coverage targets:**

- Every branch in conditional logic
- Edge cases: empty arrays, null/undefined inputs, boundary values
- Error states: invalid inputs, failed API calls (mocked)
- All handler functions exercised
- State transitions verified

### 5e. Verify Tests Pass

```bash
$PKG_MANAGER run vitest run {test-file-path} 2>&1
```

If tests fail, fix the issue and re-run (max 3 attempts). If still failing after 3 attempts, report the failure and move to the next component.

---

## Stage 6 — Anti-Pattern Scan

After all refactoring, scan the modified and created files for anti-patterns:

Use dedicated tools (not shell equivalents):

- **Grep** for `eslint-disable` in ALL modified and created files (hooks, components, tests) — any match triggers the AskUserQuestion workflow from Rule 6
- **Glob** for `use*.tsx` files (excluding `*.test.tsx`) — hooks should be `.ts`, not `.tsx`
- **Grep** for `export default` in new files — should be named exports only
- **Grep** for `useState` in component files — more than 2 occurrences suggests business logic that should have been extracted
- **Grep** for `<img` in component `.tsx` files (Next.js projects only) — should be `<Image>` from `next/image`
- **Grep** for `: any` or `as any` in all modified/created files — strict type safety violation
- **Grep** for `@ts-ignore` and `@ts-expect-error` in all modified/created files — violation
- **Grep** for `as ` type assertions (regex: `\bas \w`) in hook and component files — flag for review

Fix any violations found. For `eslint-disable` findings, follow the AskUserQuestion workflow in Rule 6 before taking action.

---

## Stage 7 — Architecture Codification

Check the **target repo** (not this skills repo) for existing documentation of the hook extraction pattern:

1. Look in: `CLAUDE.md`, `.claude/CLAUDE.md`, `.context/`, `docs/adr/`, `docs/decisions/`
2. Search for keywords: "hook", "business logic", "extraction", "custom hook"

**If not documented**, create or append based on what exists:

- If the repo has `CLAUDE.md`: append a section
- If the repo has an ADR directory: create a new ADR following existing numbering
- If neither: create `CLAUDE.md` at the repo root

**Content to add:**

```markdown
## Architecture: Business Logic in Custom Hooks

- Business logic lives in custom hooks (`use*.ts`), not in component files
- Hooks use `.ts` extension (no JSX in hooks)
- Tests co-located as `use*.test.ts` using vitest
- Pure helper functions exported alongside hooks for direct unit testing
- Named exports only, no default exports
- Server components by default in Next.js; `'use client'` only when needed
- Zero tolerance for `eslint-disable` in all files (hooks, components, tests)
- Use `next/image` `<Image>` instead of HTML `<img>` (Next.js projects)
- Strict TypeScript: no `any`, no `@ts-ignore`, no `as` assertions without justification
- ESLint must pass with `--max-warnings 0`
- All code must be Prettier-compliant
```

**If already documented:** Skip this stage.

---

## Stage 8 — Verification

Detect the package manager:

```bash
if [ -f pnpm-lock.yaml ]; then PKG="pnpm"; elif [ -f yarn.lock ]; then PKG="yarn"; else PKG="npm"; fi
```

Run full quality gates:

| Check | Command |
|-------|---------|
| Build | `$PKG run build` |
| Lint | `$PKG run lint -- --max-warnings 0` |
| Typecheck | `$PKG run typecheck` |
| Test | `$PKG run test` |
| Prettier | `$PKG exec prettier --check .` (or `$PKG run format:check` if the project has a script) |
| Type assertions | Grep all modified/created files for `: any`, `as any`, `@ts-ignore`, `@ts-expect-error` — zero tolerance, fix all violations |

**Lint `--max-warnings 0` note:** If the project's `lint` script already includes `--max-warnings 0`, the bare `$PKG run lint` is sufficient. Check `package.json` scripts first. If the lint script wraps `next lint` or `eslint` without the flag, append `-- --max-warnings 0`.

**Prettier note:** If Prettier is not configured in the project (no `.prettierrc`, `prettier.config.*`, or `prettier` key in `package.json`), skip the Prettier check and note it in the summary.

If any gate fails: read the error, fix the issue, re-run all gates from the top (max 3 fix cycles). If a script doesn't exist, skip it and note.

---

## Stage 9 — Summary Report

```
REACT REFACTOR COMPLETE
───────────────────────
Components processed: {N}
Hooks created:        {M}
Test files created:   {M}
Tests passing:        {X}/{Y}
Architecture doc:     {created | updated | already present}
Quality gates:        {ALL PASSED | FAILED — see above}
Prettier:             {COMPLIANT | NOT CHECKED — no Prettier config}
ESLint warnings:      {0 | N remaining — see above}
Type safety:          {CLEAN | N violations — see above}
next/image:           {COMPLIANT | N/A — not Next.js | N violations}

External rules: Vercel react-best-practices {loaded | not installed}
Personal overrides: 15 rules applied

Files created:
  src/hooks/useDashboardFilters.ts
  src/hooks/useDashboardFilters.test.ts
  ...

Files modified:
  src/components/Dashboard.tsx
  ...
```

---

## Error Handling

| Condition | Action |
|-----------|--------|
| No `.tsx` files found in scope | Exit with message: "No React component files found in scope." |
| vitest not installed | Log: `"vitest not found. Install: $PKG add -D vitest"` and abort |
| Hook extraction is ambiguous (unclear what to extract) | Ask user via AskUserQuestion |
| Test failures after 3 fix attempts | Report the failing tests, continue to next component |
| Quality gate failures after 3 cycles | Report and stop |
| Vercel rules file not found | Degrade gracefully, log install command |
| Component has no extractable logic | Skip and note in discovery report |
| `eslint-disable` appears necessary during refactoring | MUST use AskUserQuestion — present the lint error, the code context, and 3 options: (1) fix the code, (2) adjust ESLint config, (3) suppress with comment. Default recommendation is option 1 or 2. |
| Prettier not installed or no config found | Skip Prettier check, note in summary report |
| `--max-warnings 0` flag not supported by lint script | Try `$PKG exec eslint --max-warnings 0 .` directly; if that fails, run bare lint and manually count warnings |
