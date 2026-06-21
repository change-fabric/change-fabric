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

## 2. Opus smell analysis

Spawn one **foreground** Opus agent (`model: opus`) with:

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

## 4. Plan gate (foreground)

Determine N from the smell count and file count:

- **Trivial** (1-3 smells, 1-2 files): N=1 -- single Sonnet agent, skip
  tournament. Spawn one foreground Sonnet agent using strategy A (Conservative).
  No judge step; cherry-pick its commit directly in Step 7. If it cannot commit,
  report the reason and stop.
- **Moderate** (4-10 smells or 3-5 files): N=3.
- **Complex** (11+ smells or 6+ files): N=5.

Present smell count and N to the user via `AskUserQuestion`: "Run tournament
with N=\<N\> implementations?" (Yes / Report only / Adjust N). If
`--report-only` was passed, stop here without asking.

## 5. Parallel implementation tournament

Spawn N **foreground** Sonnet agents (`model: sonnet`, `isolation: worktree`) in
the **same response turn** so they run concurrently. Do NOT set
`run_in_background: true` -- all N must complete before Step 6 begins, and
synchronization is implicit when they are foreground.

Each agent receives the same smell findings and target files but a different
strategy directive:

- **A -- Conservative**: Fix only the highest-impact smells with the smallest
  possible diff. Prefer inlining over new abstractions. Preserve existing module
  and file structure entirely.
- **B -- Structural**: Reorganize by responsibility. Group related behavior
  together even if it means creating new files or moving methods. Optimize for
  locality of future change.
- **C -- Extract-first**: Create a named function, class, or module for every
  smell instance. Err toward more abstractions with clear names.

If N=5, add:

- **D -- Domain-model**: Look for primitive obsession and data clumps; introduce
  domain objects or value types to make implicit business concepts explicit.
- **E -- Functional**: Prefer pure functions and immutable data where the
  language supports it. Move state to the edges. Reduce side-effect surface.

Each agent must end its response with exactly this block so the orchestrator
can collect results without accessing the worktree afterward:

```
---tournament-result---
STRATEGY: <A|B|C|D|E>
STATUS: committed
COMMIT_SHA: <full 40-char sha from: git rev-parse HEAD>
DIFF:
<output of: git diff HEAD~1..HEAD>
---end-tournament-result---
```

If the agent cannot commit (tests fail, conflict, or other error), emit:

```
---tournament-result---
STRATEGY: <A|B|C|D|E>
STATUS: skipped: <reason in one line>
---end-tournament-result---
```

Steps each agent must follow:

1. Apply its strategy to fix the smells in the target files.
2. Run existing tests if present; skip any fix that breaks a test and note it.
3. Stage and commit using a HEREDOC so the trailer blank line is preserved:

   ```sh
   git add <changed files>
   git commit -m "$(cat <<'EOF'
   refactor(<strategy>): <primary smell fixed>

   Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
   EOF
   )"
   ```

4. Run `git rev-parse HEAD` and `git diff HEAD~1..HEAD`; include both verbatim
   in the result block.

## 6. Opus judge selects winner

After all N agents return (foreground means they are all done before this
step begins), parse each `---tournament-result---` block. If an agent's output
contains no result block at all, treat it as `STATUS: skipped: result block
missing`. Collect the SHA and diff for every agent with `STATUS: committed`. If
zero agents committed, report all skip reasons and stop.

Spawn one **foreground** Opus agent (`model: opus`) with:

- All committed diffs (from the result blocks -- no worktree access needed).
- The smell findings from Step 2.
- The content of `MAINTAINABILITY.md`.
- Instruction: evaluate each diff against the six MAINTAINABILITY.md outcomes
  (Higher Cohesion, Lower Coupling, Explicit Intent, Locality of Change,
  Reduced Cognitive Load, Strong Domain Modeling). Score each 1-5 per
  dimension. Return the winning strategy letter.

Return schema (include a scores entry for every strategy letter that appears
in the committed diffs you received -- do not omit strategies that ran):

```json
{
  "winner": "A|B|C|D|E",
  "scores": {
    "A": {
      "cohesion": 0,
      "coupling": 0,
      "intent": 0,
      "locality": 0,
      "cognitive_load": 0,
      "domain_model": 0
    },
    "B": {
      "cohesion": 0,
      "coupling": 0,
      "intent": 0,
      "locality": 0,
      "cognitive_load": 0,
      "domain_model": 0
    },
    "C": {
      "cohesion": 0,
      "coupling": 0,
      "intent": 0,
      "locality": 0,
      "cognitive_load": 0,
      "domain_model": 0
    }
  },
  "reasoning": "one sentence"
}
```

## 7. Apply and report

Look up the SHA for the winning strategy from the result blocks collected in
Step 5 (not from the Opus judge). Cherry-pick it onto the current branch:

```sh
git cherry-pick <sha-from-winning-agent>
```

If cherry-pick fails due to conflict, write the winning diff to a temp file
and apply it:

```sh
# Write the diff from the result block to a temp file first
git apply /tmp/pst-refactor-winner.patch
```

Use the Write tool to write the diff string to `/tmp/pst-refactor-winner.patch`
before running that command.

Report: winning strategy, Opus reasoning, scores for each strategy, smells
fixed vs. skipped, test results, and any agents that skipped with their reason.

## Notes

- Rule 24 best-of-N: N=1 for trivial, N=3 for moderate, N=5 for complex.
- Rule 15 two-hats applies to every implementation agent: no behavior changes.
- Rule 7 applies if the result goes to a PR: adversarial review before merge.
- For very large codebases (50+ files), scope with a path first:
  `/pst:refactor src/auth` then widen.
