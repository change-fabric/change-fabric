---
name: pst:refactor
description: Comprehensive Fowler maintainability refactor pass across the entire codebase. An Opus background agent analyzes all code files against the 16-smell rubric in MAINTAINABILITY.md, produces a prioritized smell inventory, then parallel Sonnet agents fix each file in isolated worktrees (behavior-preserving, two hats per rule 15). Run any time you want human maintainability optimized across the board, independent of feature work.
argument-hint: "[path-or-glob] [--report-only]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, AskUserQuestion
---

# /pst:refactor

Comprehensive Fowler code-smell pass. Opus analyzes the full codebase (or a
scoped path), Sonnet fixes each smell in an isolated worktree. Always the
second hat -- behavior stays identical, only structure improves.

## 1. Setup

Resolve the MAINTAINABILITY.md rubric path at runtime:

```sh
LEDGER="$(cat ~/.claude/pst/ledger-path 2>/dev/null)"
MAINT="$(dirname "$LEDGER")/../MAINTAINABILITY.md"
cat "$MAINT"
```

Determine the scan root from `$ARGUMENTS`:

- **Path or glob provided**: scan only that subtree.
- **No argument**: scan the entire repo working tree.

Discover all code files (exclude lockfiles, generated files, docs):

```sh
git ls-files | grep -Ev '\.(lock|snap|min\.(js|css)|pb\.go|pb_test\.go)$' \
  | grep -Ev '^(docs?/|\.github/|dist/|build/)' \
  | grep -E '\.(rb|py|ts|tsx|js|jsx|go|rs|java|kt|swift|ex|exs|cs|cpp|c|h)$'
```

## 2. Opus smell analysis (background)

Spawn one background Opus agent (`model: opus`) with:

- The full content of `MAINTAINABILITY.md` (read via the path resolved above).
- The list of code files from step 1.
- Read every file in the list.
- Instruction:

  ```
  You are a maintainability auditor. For each file, identify which of the 16
  canonical Fowler code smells are present. For every finding, record:
    - file path and approximate line range
    - smell name
    - one-sentence description of the specific instance
    - recommended refactoring (Extract Function, Move Method, etc.)

  Rank findings by impact: smells that would most reduce future change cost
  come first. Smells that require a behavior change to fix (e.g. API redesign
  that breaks callers) are out of scope -- skip them.

  Return a JSON array:
  [
    {
      "file": "path/to/file.rb",
      "smell": "Duplicated Code",
      "lines": "42-61",
      "detail": "Login and signup both inline-validate email format.",
      "fix": "Extract Function: extract validate_email into a shared helper."
    }
  ]
  ```

## 3. Present findings and gate

Group findings by file. Present as a summary table:

```
File                    Smells   Top smell
src/auth/session.rb        3     Duplicated Code (lines 42-61)
src/api/handler.ts         2     Long Function (lines 120-180)
...
```

If no findings: report "No smells detected." and stop.

If `--report-only` was passed, stop here.

Use `AskUserQuestion`: **Apply all fixes in isolated worktrees?** (Yes / Report
only). Treat no objection as Yes.

## 4. Parallel Sonnet implementers (isolated worktrees)

Group findings by file. Spawn one background Sonnet agent per file
(`model: sonnet`, `isolation: worktree`) with:

- The file content.
- The smell findings for that file.
- Instruction:

  ```
  Apply each refactoring listed below to this file. Rules:
  - Behavior-preserving only. Do not change any observable behavior.
  - Run existing tests if a test runner is available; skip any fix that
    breaks a test and note it.
  - After all fixes: stage the changed file and commit:
      git add <file>
      git commit -m "refactor(<file>): <primary smell fixed>"
    Include the co-author trailer:
      Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
  - If no fix is safe to apply, commit nothing and return a skip reason.
  ```

## 5. Report

After all worktree agents complete:

- List each file: smells fixed, smells skipped (with reason), test result.
- If any fix broke a test, name the fix and the failing test.
- State total smells fixed vs. skipped.

## Notes

- Rule 15 two-hats: every commit from this skill is a pure refactor. If a
  fix requires a behavior change, skip it and surface it as a follow-up.
- Rule 7 applies if you intend to merge the result via PR: adversarial review
  before merge.
- For very large codebases (> 50 files), run with a scoped path first:
  `/pst:refactor src/auth` then widen.
