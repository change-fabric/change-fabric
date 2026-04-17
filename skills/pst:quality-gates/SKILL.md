---
name: pst:quality-gates
description: Establish comprehensive quality gates in a project - lint, typecheck, build, format, test coverage - with 80% coverage on pure *.ts functions
argument-hint: "[--dry-run] [--skip-refactor]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, AskUserQuestion
---

# Quality Gates: Establish & Enforce

Bootstrap a comprehensive, opinionated quality-gate configuration in the target project. After running this skill, the project will have lint, typecheck, build, format, and test-coverage scripts that enforce strict standards - and the tooling config to back them up.

---

## Input

<arguments> #$ARGUMENTS </arguments>

**Parse arguments:**

- `--dry-run` - analyze the project and print what would change, but do not modify any files
- `--skip-refactor` - skip the `/pst:react-refactor` pass (Stage 6). Useful if you only want config scaffolding without code changes.

**Default behavior (no arguments):** Full setup - configure all quality gates, then run `/pst:react-refactor` to maximize test coverage.

---

## Stage 1 - Project Discovery

Gather everything needed to make informed decisions about what to install and configure.

### 1a. Package Manager Detection

```bash
if [ -f pnpm-lock.yaml ]; then PKG="pnpm"
elif [ -f yarn.lock ]; then PKG="yarn"
elif [ -f bun.lockb ] || [ -f bun.lock ]; then PKG="bun"
else PKG="npm"; fi
```

### 1b. Framework Detection

Determine the project's framework stack by inspecting `package.json` dependencies and config files:

| Signal                                   | Framework                    |
| ---------------------------------------- | ---------------------------- |
| `next` in dependencies                   | Next.js                      |
| `@remix-run/*` in dependencies           | Remix                        |
| `vite` in devDependencies (no framework) | Vite SPA                     |
| `react` in dependencies (no Next/Remix)  | React (CRA or custom)        |
| No React dependency                      | Non-React TypeScript project |

Also detect:

- **TypeScript** - `tsconfig.json` exists
- **ESLint** - `.eslintrc*`, `eslint.config.*`, or `eslintConfig` in package.json
- **Prettier** - `.prettierrc*`, `prettier.config.*`, or `prettier` key in package.json
- **Test runner** - `vitest.config.*`, `jest.config.*`, or test-related scripts in package.json
- **Existing scripts** - read `package.json` `scripts` to know what already exists

### 1c. File Inventory

Count files that will be subject to quality gates:

```bash
# TypeScript source files (non-test)
TS_FILES=$(find src -name '*.ts' ! -name '*.test.ts' ! -name '*.spec.ts' ! -path '*/node_modules/*' 2>/dev/null | wc -l)
TSX_FILES=$(find src -name '*.tsx' ! -name '*.test.tsx' ! -name '*.spec.tsx' ! -path '*/node_modules/*' 2>/dev/null | wc -l)
TEST_FILES=$(find src \( -name '*.test.ts' -o -name '*.spec.ts' \) ! -path '*/node_modules/*' 2>/dev/null | wc -l)
```

### 1d. Discovery Report

```
QUALITY GATES - PROJECT DISCOVERY
──────────────────────────────────
Package manager:  {pnpm|yarn|npm|bun}
Framework:        {Next.js|Remix|Vite|React|TypeScript}
TypeScript:       {yes|no}
ESLint:           {yes (flat config)|yes (legacy)|no}
Prettier:         {yes|no}
Test runner:      {vitest|jest|none}
Source files:     {N} .ts, {M} .tsx
Test files:       {K} existing

Existing scripts:
  build:          {present|missing}
  lint:           {present|missing}
  typecheck:      {present|missing}
  format:         {present|missing}
  format:check:   {present|missing}
  test:           {present|missing}
  test:coverage:  {present|missing}
```

**If `--dry-run`:** Continue through all stages but only report what would change - do not modify files.

---

## Stage 2 - TypeScript Strict Mode

Ensure TypeScript is configured for strict type safety.

### 2a. Install TypeScript (if missing)

If `typescript` is not in devDependencies:

```bash
$PKG add -D typescript
```

For Next.js projects, also ensure `@types/react` and `@types/node` are present.

### 2b. Enforce Strict tsconfig

Read `tsconfig.json`. Ensure these compiler options are set:

```jsonc
{
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitOverride": true,
    "noFallthroughCasesInSwitch": true,
    "forceConsistentCasingInFileNames": true,
    "verbatimModuleSyntax": true,
  },
}
```

**Rules:**

- If `strict` is already `true`, leave it. If `false` or missing, set it to `true`.
- Do NOT remove existing options - only add or upgrade. Preserve comments.
- If the project uses `extends` (e.g., `@tsconfig/next`), check what the base provides and only add what's missing.
- `verbatimModuleSyntax` may conflict with some setups (e.g., CommonJS projects). If enabling it causes immediate typecheck failures, remove it and note why.

### 2c. Add typecheck Script

If `package.json` does not have a `typecheck` script:

```json
"typecheck": "tsc --noEmit"
```

If the project is Next.js and has no custom typecheck, use `tsc --noEmit` (not `next lint` - that's linting, not typechecking).

---

## Stage 3 - ESLint Configuration

### 3a. Install ESLint (if missing)

If ESLint is not installed:

- **Next.js:** `eslint` and `eslint-config-next` should already be present. If not: `$PKG add -D eslint eslint-config-next`
- **Other React:** `$PKG add -D eslint @eslint/js typescript-eslint eslint-plugin-react-hooks`
- **Non-React TS:** `$PKG add -D eslint @eslint/js typescript-eslint`

### 3b. Configure for Zero Warnings

Read the existing ESLint config. The goal: **all lint runs produce zero warnings**.

**If the project already has an ESLint config:**

- Do NOT rewrite it from scratch. Respect the team's rule choices.
- Ensure the lint script enforces `--max-warnings 0` (see Stage 5).
- If rules are set to `"warn"` that should be `"error"` for a strict gate, leave them - the `--max-warnings 0` flag treats warnings as errors at the CLI level.

**If no ESLint config exists**, create a minimal flat config (`eslint.config.mjs`):

```javascript
import js from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  js.configs.recommended,
  ...tseslint.configs.strictTypeChecked,
  {
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
  },
  {
    ignores: ["dist/", "build/", ".next/", "node_modules/", "coverage/"],
  },
);
```

For Next.js, layer on `eslint-config-next`. For React without Next.js, add `eslint-plugin-react-hooks`.

### 3c. Ban `any` via Lint Rules

Ensure these rules are active (either via `strictTypeChecked` preset or explicit config):

- `@typescript-eslint/no-explicit-any` - error
- `@typescript-eslint/no-unsafe-assignment` - error
- `@typescript-eslint/no-unsafe-call` - error
- `@typescript-eslint/no-unsafe-member-access` - error
- `@typescript-eslint/no-unsafe-return` - error

If the project's existing config already extends `strictTypeChecked` or has these rules, no changes needed.

---

## Stage 4 - Prettier Configuration

### 4a. Install Prettier (if missing)

```bash
$PKG add -D prettier
```

### 4b. Create Config (if missing)

If no Prettier config exists, create `.prettierrc`:

```json
{}
```

An empty config is valid - Prettier's defaults are sensible. If the project has preferences (tabs vs spaces, print width, etc.), respect them.

### 4c. Create .prettierignore (if missing)

```
dist/
build/
.next/
coverage/
pnpm-lock.yaml
yarn.lock
package-lock.json
```

---

## Stage 5 - Package.json Scripts

This is the core deliverable. Ensure `package.json` has all five quality-gate scripts plus a unified `validate` script.

### Target Scripts

Read the current `package.json` scripts and merge - do NOT overwrite existing scripts unless they're broken.

| Script          | Command                                                                                                    | Notes                                                                                                              |
| --------------- | ---------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `build`         | Framework-dependent                                                                                        | Next.js: `next build`. Vite: `vite build`. Keep existing if present.                                               |
| `lint`          | `eslint . --max-warnings 0`                                                                                | If existing script lacks `--max-warnings 0`, append it. For Next.js `next lint`, use `next lint --max-warnings 0`. |
| `typecheck`     | `tsc --noEmit`                                                                                             | Add if missing.                                                                                                    |
| `format`        | `prettier --write .`                                                                                       | Add if missing. Keep existing if present.                                                                          |
| `format:check`  | `prettier --check .`                                                                                       | Add if missing. Used in CI.                                                                                        |
| `test`          | `vitest run`                                                                                               | Add if missing. Keep existing if present.                                                                          |
| `test:coverage` | `vitest run --coverage`                                                                                    | See Stage 5b for coverage config.                                                                                  |
| `validate`      | `$PKG run build && $PKG run lint && $PKG run typecheck && $PKG run format:check && $PKG run test:coverage` | Runs all gates in sequence. Single command for CI.                                                                 |

### 5a. Script Merging Rules

- **Existing script is equivalent or better:** Keep it. Example: lint script already has `--max-warnings 0`.
- **Existing script is weaker:** Strengthen it. Example: lint script runs `eslint .` without `--max-warnings 0` - add the flag.
- **No existing script:** Add the target script.
- **Existing script is custom/complex:** Do NOT replace. If it's missing `--max-warnings 0`, try appending. If that's not feasible (e.g., the script calls a wrapper), log a warning and ask the user.

### 5b. Test Coverage Configuration

Install vitest coverage provider if not present:

```bash
$PKG add -D vitest @vitest/coverage-v8
```

If the project uses Jest, do NOT migrate to vitest. Instead, configure Jest coverage equivalently and note the deviation.

**Jest coverage equivalent** in `jest.config.ts` (or `jest.config.js`):

```typescript
export default {
  collectCoverageFrom: [
    "src/**/*.ts",
    "!src/**/*.tsx",
    "!src/**/*.test.ts",
    "!src/**/*.spec.ts",
    "!src/**/*.d.ts",
    "!src/**/index.ts",
    "!src/**/__mocks__/**",
    "!src/**/__tests__/**",
    "!src/**/types.ts",
    "!src/**/types/**",
  ],
  coverageThreshold: {
    global: {
      statements: 80,
      branches: 80,
      functions: 80,
      lines: 80,
    },
  },
};
```

**Coverage threshold configuration** in `vitest.config.ts` (or equivalent):

```typescript
export default defineConfig({
  test: {
    coverage: {
      provider: "v8",
      include: ["src/**/*.ts"],
      exclude: [
        "src/**/*.tsx",
        "src/**/*.test.ts",
        "src/**/*.spec.ts",
        "src/**/*.d.ts",
        "src/**/index.ts",
        "src/**/__mocks__/**",
        "src/**/__tests__/**",
        "src/**/types.ts",
        "src/**/types/**",
      ],
      thresholds: {
        statements: 80,
        branches: 80,
        functions: 80,
        lines: 80,
      },
    },
  },
});
```

**Critical design decision:** Coverage thresholds apply to `*.ts` files only, NOT `*.tsx` files. This is intentional:

- `*.ts` files contain business logic (hooks, utilities, services) that MUST be thoroughly tested
- `*.tsx` files contain UI components whose logic should be extracted to hooks via `/pst:react-refactor`
- This creates a positive feedback loop: to hit 80% coverage, developers extract testable logic from `.tsx` into `.ts` hooks

**If vitest.config.ts already exists:** Merge the coverage configuration. Do NOT overwrite other test settings (e.g., setup files, environment, globals).

**If the project uses a shared vite.config.ts with test config:** Add coverage config there instead of creating a separate vitest.config.ts.

---

## Stage 6 - React Refactor Pass

**Skip if `--skip-refactor` or `--dry-run` or project has no `.tsx` files.**

This stage leverages `/pst:react-refactor` to extract business logic from `.tsx` components into testable `.ts` hooks, directly increasing the test-coverable surface area under the 80% threshold.

### 6a. Assess Coverage Gap

Run the coverage report to see where the project stands:

```bash
$PKG run test:coverage 2>&1 || true
```

Parse the coverage output. If overall coverage is already >= 80% on `*.ts` files, skip this stage.

### 6b. Identify High-Impact Extraction Targets

Look for `.tsx` components with substantial business logic that, if extracted to `.ts` hooks, would bring the most coverage improvement:

- Components with multiple `useState`/`useEffect` calls
- Components with data transformation logic inline
- Components with conditional rendering driven by complex logic
- Components with form validation or API orchestration inline

### 6c. Invoke React Refactor

Use an Agent to run the `/pst:react-refactor` skill on the identified components:

```
Agent:
  description: "React refactor: extract business logic to testable hooks"
  prompt: |
    Run /pst:react-refactor on the following files to extract business logic
    into testable *.ts hooks. The goal is to maximize test coverage on pure
    functions and hooks.

    Target files: {list of .tsx files with extractable logic}

    After extraction, write comprehensive tests for the new hooks to achieve
    >= 80% coverage on all branches, statements, functions, and lines.
```

### 6d. Re-run Coverage

After the refactor pass, re-run coverage to verify improvement:

```bash
$PKG run test:coverage
```

---

## Stage 7 - Verification

Run all quality gates to confirm the setup works end-to-end.

### 7a. Sequential Gate Execution

Run each gate in order. If one fails, fix the issue before proceeding.

```bash
$PKG run build
$PKG run lint
$PKG run typecheck
$PKG run format:check
$PKG run test:coverage
```

### 7b. Fix Loop

If any gate fails:

1. Read the error output
2. Fix the root cause (config issue, missing dependency, code violation)
3. Re-run ALL gates from the top (a fix for one gate can break another)
4. Max 5 fix cycles. If still failing, report the remaining issues.

### 7c. Anti-Pattern Scan

After all gates pass, scan for violations of core standards:

- **Grep** for `: any` and `as any` in `src/**/*.ts` files - strict type safety violation
- **Grep** for `@ts-ignore` and `@ts-expect-error` - violation
- **Grep** for `eslint-disable` in all source files - zero tolerance (shared rule S5)
- **Grep** for `export default` in new files - should be named exports only (shared rule S1)

Fix any violations found. For `eslint-disable` findings, follow the AskUserQuestion workflow from shared rule S5.

---

## Stage 8 - Architecture Codification

Document the quality gate setup in the target project so future developers (and LLMs) know the standards.

### 8a. Check Existing Documentation

Search the target repo for existing quality gate documentation:

1. Look in: `CLAUDE.md`, `.claude/CLAUDE.md`, `.context/`, `docs/adr/`, `docs/decisions/`, `CONTRIBUTING.md`
2. Search for keywords: "quality gate", "coverage", "lint", "typecheck"

### 8b. Add or Update Documentation

If not already documented, append to the project's `CLAUDE.md` (create if it doesn't exist):

```markdown
## Quality Gates

All PRs must pass the full validation suite (`$PKG run validate`):

| Gate          | Script                   | Standard                           |
| ------------- | ------------------------ | ---------------------------------- |
| Build         | `$PKG run build`         | Zero errors                        |
| Lint          | `$PKG run lint`          | Zero warnings (`--max-warnings 0`) |
| Typecheck     | `$PKG run typecheck`     | Strict mode, no `any` types        |
| Format        | `$PKG run format:check`  | Prettier-compliant                 |
| Test coverage | `$PKG run test:coverage` | 80% on all `*.ts` files            |

### Coverage Policy

- **80% threshold** on statements, branches, functions, and lines for `*.ts` files
- **`*.tsx` files are excluded** from coverage thresholds - UI logic should be extracted to testable hooks
- Use `/pst:react-refactor` to extract business logic from components into `use*.ts` hooks
- Pure helper functions exported from hook files enable direct unit testing without `renderHook`
```

**If already documented:** Verify it matches the current configuration and update if needed.

---

## Stage 9 - Summary Report

```
QUALITY GATES ESTABLISHED
─────────────────────────
Project:          {name from package.json}
Package manager:  {pnpm|yarn|npm|bun}
Framework:        {Next.js|Remix|Vite|React|TypeScript}

Scripts configured:
  build:          {added|updated|already present}
  lint:           {added|updated|already present} (--max-warnings 0)
  typecheck:      {added|updated|already present} (strict mode)
  format:         {added|updated|already present}
  format:check:   {added|updated|already present}
  test:           {added|updated|already present}
  test:coverage:  {added|updated|already present} (80% threshold on *.ts)
  validate:       {added|updated|already present}

Config changes:
  tsconfig.json:  {strict mode enforced|already strict|created}
  ESLint:         {configured|updated|already present}
  Prettier:       {configured|already present}
  Vitest coverage:{configured|updated|already present}

Packages installed: {list of added devDependencies}

React refactor:   {N components processed|skipped (--skip-refactor)|skipped (no .tsx)|skipped (coverage already >= 80%)}

Verification:     {ALL GATES PASSED|FAILED - see above}
  build:          {PASS|FAIL|N/A}
  lint:           {PASS|FAIL|N/A}
  typecheck:      {PASS|FAIL|N/A}
  format:         {PASS|FAIL|N/A}
  test:coverage:  {PASS|FAIL|N/A}

Architecture doc: {created|updated|already present}
```

---

## Error Handling

| Condition                                                        | Action                                                                                                                            |
| ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Not a Node.js project (no `package.json`)                        | Stop: "No package.json found. This skill requires a Node.js project."                                                             |
| Not a TypeScript project (no `tsconfig.json` and no `.ts` files) | Stop: "No TypeScript found. This skill targets TypeScript projects."                                                              |
| Conflicting test runners (both vitest and jest)                  | Ask user via AskUserQuestion which to configure for coverage                                                                      |
| `--max-warnings 0` breaks existing lint (too many warnings)      | Fix the warnings. If > 50 warnings, ask user whether to fix incrementally or enforce immediately.                                 |
| Coverage threshold unreachable (< 80% with no testable code)     | Lower threshold for initial setup, log a TODO to raise it as tests are added                                                      |
| Package install fails                                            | Stop with error and suggest manual installation                                                                                   |
| Build fails after config changes                                 | Revert the config change that caused it and try an alternative approach                                                           |
| `strict: true` causes hundreds of type errors                    | Ask user via AskUserQuestion: (1) fix all now, (2) enable incrementally with `// @ts-expect-error` TODOs, (3) skip strict for now |
| Project uses monorepo (workspaces)                               | Apply to the root or ask which workspace to configure                                                                             |
| `verbatimModuleSyntax` conflicts                                 | Remove it and note in summary                                                                                                     |
| Existing vitest config has conflicting coverage settings         | Merge carefully - preserve existing `include`/`exclude` and add thresholds                                                        |
