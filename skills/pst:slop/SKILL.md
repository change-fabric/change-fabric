---
name: pst:slop
description: Detect and remove common AI-generated slop from branch changes or the entire repo
argument-hint: "[--repo | --dry-run | --auto]"
allowed-tools: Bash, Read, Edit, Grep, Glob, AskUserQuestion
---

# Slop Sweep

Scan for and remove common patterns of AI-generated slop. By default, scopes to changes on the current branch vs. the default branch. With `--repo`, scans the entire repository.

**Interactive by default.** After detection, present findings and ask the user what to fix before touching anything. The `--auto` flag skips confirmation and applies all safe fixes autonomously. `--dry-run` reports only.

---

## Input

<arguments> #$ARGUMENTS </arguments>

**Parse arguments:**

- `--repo` - scan the entire repository instead of just branch changes
- `--dry-run` - report findings without modifying any files, no confirmation prompts
- `--auto` - skip confirmation prompts and apply all safe fixes autonomously
- No arguments - scan branch changes, present findings, ask before fixing

---

## Phase 1 - Scope

Determine what files to scan.

```bash
BRANCH=$(git branch --show-current 2>/dev/null)
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
```

**Branch mode (default):**

```bash
MERGE_BASE=$(git merge-base "origin/$DEFAULT_BRANCH" HEAD 2>/dev/null || git merge-base "$DEFAULT_BRANCH" HEAD)
CHANGED_FILES=$(git diff --name-only "$MERGE_BASE...HEAD" 2>/dev/null)
```

If on the default branch or no changed files, fall back to `--repo` mode automatically and note this in output.

**Repo mode (`--repo`):**

Use Glob to collect all source files: `**/*.{ts,tsx,js,jsx,py,go,rs,md,mdx,json,yaml,yml}`. Exclude `node_modules/`, `dist/`, `build/`, `.next/`, `vendor/`, `*.lock`, `*.min.*`.

Store the file list as `SCAN_FILES`.

---

## Phase 2 - Detect

Scan `SCAN_FILES` for each slop category. For each finding, record:

```
{ file, line, category, severity, description, suggestion }
```

Severity levels: `auto-fix` (safe to fix without asking), `review` (fix is likely correct but warrants a glance), `flag` (needs human judgment).

### Category 1: Em Dashes

**Severity:** `auto-fix`

Search for the em dash character (U+2014) and the en dash (U+2013) in all scanned files.

- In prose/markdown: replace em dash with ` - ` (space-hyphen-space)
- In code comments: replace em dash with ` - `
- In string literals: replace em dash with `-`
- Exception: third-party files, vendored code, or quoted text from external sources

### Category 2: Excessive Documentation

**Severity:** `review`

In **branch mode**, compare the diff to find documentation added alongside code changes. Flag when:

- A JSDoc/docstring was added to a function whose name and signature already make the behavior obvious (e.g., `/** Gets the user by ID */ function getUserById(id: string)`)
- Inline comments that simply restate the next line of code (e.g., `// increment counter` before `counter++`)
- README or doc file changes that were not requested in the commit messages
- Comments that narrate "what" rather than "why"

In **repo mode**, scan for the same patterns across all files.

Do NOT flag:
- Comments explaining non-obvious business logic or "why" decisions
- API documentation for public interfaces
- License headers
- Type documentation for complex generics

### Category 3: Disabled Quality Gates

**Severity:** `auto-fix` (when removable) or `flag` (when the underlying issue needs fixing)

Search for:

- `eslint-disable` / `eslint-disable-next-line` without a justification comment
- `@ts-ignore` / `@ts-expect-error` without a justification comment
- `// @ts-nocheck`
- `/* istanbul ignore */` / `/* c8 ignore */`
- `# type: ignore` (Python)
- `#nosec` (Go)
- `// nolint` (Go)
- `.eslintignore` entries added in the diff
- `skipLibCheck: true` added to tsconfig

For each, check whether removing the suppression causes a real issue. If the underlying code is correct and the suppression is unnecessary, severity is `auto-fix`. If removing it would surface a real error, severity is `flag` with a note about what needs fixing.

### Category 4: Band-Aid Exclusions

**Severity:** `flag`

Search for patterns where something was excluded rather than fixed:

- `it.skip(` / `xit(` / `xdescribe(` / `test.skip(` - skipped tests
- `.only(` - focused tests left in (accidental commit)
- Files added to `.gitignore` that look like source (not build artifacts)
- `exclude` or `ignore` patterns added to config files (eslint, tsconfig `paths`, jest `modulePathIgnorePatterns`) that carve out source code
- `any` casts used to silence type errors rather than fixing the type (e.g., `as any`, `as unknown as TargetType`)
- `catch (e) { }` or `catch (_) { }` - empty catch blocks that swallow errors silently

### Category 5: Over-Complicated Abstractions

**Severity:** `review`

Look for patterns that suggest unnecessary indirection:

- **Single-use wrappers:** A function/class that is only called once and adds no logic beyond forwarding to another function. Use Grep to check call count.
- **Unnecessary factory patterns:** Functions that return functions that just call another function
- **Config objects for one thing:** An options/config type with a single field
- **Re-export files:** `index.ts` barrel files that re-export from a single module with no aggregation value
- **Adapter layers with no adaptation:** Wrapper classes/functions that pass through every argument unchanged

Do NOT flag:
- Abstractions that exist for testability (dependency injection)
- Re-exports that aggregate multiple modules into a public API
- Wrappers that add error handling, logging, or caching

### Category 6: Dead Code & Leftover Artifacts

**Severity:** `auto-fix`

Search for:

- `console.log` / `console.debug` / `console.warn` left in production code (not in test files, not in logging utilities)
- Commented-out code blocks (more than 2 consecutive commented lines that look like code, not documentation)
- Unused imports (if detectable from the file - e.g., an import that does not appear elsewhere in the file)
- `TODO` / `FIXME` / `HACK` / `XXX` comments introduced in the branch diff (in branch mode only)

For `TODO`/`FIXME` in branch mode: severity is `review` rather than `auto-fix`. These might be intentional placeholders, but they should not ship.

### Category 7: Error Theater

**Severity:** `review`

Patterns where error handling exists but is misleading or useless:

- `try { ... } catch (e) { throw e }` - catch-and-rethrow with no transformation
- `catch (e) { console.log(e) }` without rethrowing or returning an error state
- Error messages that are generic strings instead of including context (e.g., `throw new Error("Something went wrong")`)
- `|| undefined` / `|| null` fallbacks that hide failures from callers

### Category 8: Type Safety Escapes

**Severity:** `flag`

- `as any` casts
- `as unknown as X` double casts
- `// @ts-expect-error` used to bypass strict checks rather than fixing the type
- Generic `Record<string, any>` where a proper interface exists
- `Function` type (instead of a specific signature)

---

## Phase 3 - Present & Confirm

After detection, present ALL findings grouped by category as a summary table:

```
SLOP SCAN RESULTS
-----------------
Scope: {branch (N files) | repo (N files)}

  Category                      Found   Fixable   Needs review
  -------                       -----   -------   ------------
  Em dashes                     {N}     {N}       -
  Excessive documentation       {N}     -         {N}
  Disabled quality gates        {N}     {N}       {N}
  Band-aid exclusions           {N}     -         {N}
  Over-complicated abstractions {N}     -         {N}
  Dead code & artifacts         {N}     {N}       {N}
  Error theater                 {N}     -         {N}
  Type safety escapes           {N}     -         {N}
```

Then list the specific findings, grouped by file, with line numbers and descriptions.

### If `--dry-run`:

Print the summary and findings. Stop. No modifications.

### If `--auto`:

Skip confirmation. Proceed directly to Phase 4 for all auto-fix and review items.

### If interactive (default - no `--auto`, no `--dry-run`):

**REQUIRED:** Use AskUserQuestion to confirm before making ANY changes. Present the findings summary above, then ask:

> I found {N} instances of slop across {M} files. Here is my plan:
>
> - **Auto-fix ({N}):** Em dashes, dead code, unnecessary suppressions
> - **Review fixes ({N}):** Excessive docs, error theater, abstractions
> - **Flag only ({N}):** Band-aid exclusions, type safety escapes
>
> What would you like me to do?
> 1. Fix all auto-fix + review items
> 2. Fix auto-fix items only, show me review items
> 3. Walk me through each category one at a time
> 4. Skip - just show me the report

Wait for the user's response. Respect their choice exactly:

- **Option 1:** Apply all auto-fix and review items, show flags.
- **Option 2:** Apply auto-fix items only. Print review items as suggestions.
- **Option 3:** For each category that has findings, present the specific findings and use AskUserQuestion: "Fix these {N} items? (yes / no / let me pick)". If "let me pick", present each finding individually.
- **Option 4:** Print the full report. Do not modify any files.

If the user gives a freeform answer (e.g., "just fix the em dashes" or "skip the documentation ones"), interpret their intent and confirm: "Got it - I'll fix {specific categories} and leave the rest. Correct?"

---

## Phase 4 - Fix

Apply only the fixes the user approved (or all safe fixes if `--auto`).

### Auto-fix items

1. Replace em dashes with appropriate hyphens
2. Remove unnecessary `eslint-disable` / `@ts-ignore` comments (verify the code compiles without them first)
3. Remove obvious `console.log` statements from production code
4. Remove commented-out code blocks

### Review items (only if user approved)

Apply the fix and note it in output so the user can verify.

### Flag items

Never auto-fix. Always present to the terminal only:

```
[FLAG] {file}:{line} - {category}: {description}
  Why: {explanation of the underlying issue}
  Suggestion: {what should be done instead}
```

After each file modification, verify the file is still syntactically valid by checking for obvious issues. Do NOT run the full build after every fix - batch them.

---

## Phase 5 - Verify

**Skip if `--dry-run` or no fixes were applied.**

Run a lightweight verification to ensure fixes did not break anything:

```bash
# Check if project has quality scripts
if [ -f package.json ]; then
  # Typecheck first (fastest signal for breakage)
  if npm run typecheck --if-present 2>/dev/null; then
    echo "Typecheck: PASS"
  else
    echo "Typecheck: FAIL - reverting last batch"
    git checkout -- .
    echo "Fixes reverted. Run with --dry-run to see findings without modification."
    exit 1
  fi
fi
```

If typecheck fails after fixes, revert all changes and suggest `--dry-run` mode.

---

## Phase 6 - Report

Print a final summary:

```
SLOP SWEEP
----------
Scope:       {branch (N files) | repo (N files)}
Branch:      {BRANCH}

RESULTS
-------
Em dashes:                {N found, N fixed}
Excessive documentation:  {N found, N fixed}
Disabled quality gates:   {N found, N fixed, N flagged}
Band-aid exclusions:      {N flagged}
Over-complicated abstractions: {N found}
Dead code & artifacts:    {N found, N fixed}
Error theater:            {N found, N fixed}
Type safety escapes:      {N flagged}

Total: {N} fixed, {N} to review, {N} flagged for manual attention
```

If `--dry-run`, replace "fixed" with "would fix" throughout.

---

## Error Handling

| Condition | Action |
|---|---|
| Not a git repo | Stop: "Not a git repo." |
| No changed files on branch | Fall back to `--repo` mode with a note |
| Typecheck fails after fixes | Revert all changes, suggest `--dry-run` |
| File is binary | Skip silently |
| File is in `node_modules` or vendored | Skip silently |
