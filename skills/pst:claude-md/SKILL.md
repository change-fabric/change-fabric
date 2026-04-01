---
name: pst:claude-md
description: Validate CLAUDE.md and MEMORY.md files against Anthropic's official compliance rules, with optional auto-fix
argument-hint: "[--strict | --json | --fix | --install | --no-color | --help]"
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, AskUserQuestion
---

# CLAUDE.md Compliance Checker

Validate all `CLAUDE.md` and `MEMORY.md` files in the current project against Anthropic's official recommendations. Every rule is sourced from Anthropic documentation with exact URLs.

**Deterministic, zero-dependency.** This skill runs a self-contained Bash script that requires nothing beyond standard coreutils. It exits nonzero if any FAIL-severity check does not pass.

---

## Input

<arguments> #$ARGUMENTS </arguments>

**Parse arguments:**

- `--strict` - promote all WARNs to FAILs
- `--json` - output results as a JSON array for CI integration
- `--fix` - eagerly fix ALL failing rules. For oversized files, analyzes sections and relocates reference material to domain-specific files (`.context/`, `.claude/rules/`) while leaving compact pointers in CLAUDE.md. For vague patterns, rewrites them to be concrete. Interactive -- presents the plan before executing.
- `--install` - install defense-in-depth: commits the checker script into the repo, creates a GitHub Actions workflow, and adds a Husky pre-commit hook. Idempotent -- safe to re-run.
- `--no-color` - disable color output
- `--help` - print usage and exit
- No arguments - run all checks with color output, normal severity levels

---

## Execution

Write the script below to a temporary file, make it executable, and run it with the parsed arguments against the current working directory. After the script completes, read its output and present to the user. If `--fix` was used and the script recommends changes, apply them.

### The Script

Write this exact script to `/tmp/check-claude-md.sh` and execute it:

```bash
#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# check-claude-md.sh -- CLAUDE.md & MEMORY.md Compliance Checker
#
# Validates project memory files against Anthropic's official recommendations.
# Every rule cites its source of truth from Anthropic documentation.
#
# Usage: ./check-claude-md.sh [project_root] [--strict] [--json] [--fix] [--no-color] [--help]
#        Defaults to current directory if no argument provided.
#
# Exit codes:
#   0 -- All checks passed (warnings may have been emitted)
#   1 -- One or more FAIL-severity checks did not pass
# ============================================================================

# --- Globals ---
PROJECT_ROOT=""
STRICT=false
JSON_OUTPUT=false
FIX_MODE=false
INSTALL_MODE=false
NO_COLOR=false
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0
declare -a JSON_RESULTS=()

# --- Color helpers ---
RED=""
YELLOW=""
GREEN=""
CYAN=""
BOLD=""
RESET=""

init_colors() {
  if [[ "$NO_COLOR" == false ]] && [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    YELLOW=$'\033[0;33m'
    GREEN=$'\033[0;32m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
  fi
}

# --- Output helpers ---
print_pass() {
  local rule_id="$1" desc="$2" detail="$3"
  ((PASS_COUNT++))
  ((TOTAL_COUNT++))
  if [[ "$JSON_OUTPUT" == true ]]; then
    JSON_RESULTS+=("{\"rule\":\"$rule_id\",\"status\":\"PASS\",\"description\":\"$desc\",\"detail\":\"$detail\"}")
  else
    printf "${GREEN}[PASS]${RESET} %-45s ${CYAN}(%s)${RESET}\n" "$rule_id: $desc" "$detail"
  fi
}

print_warn() {
  local rule_id="$1" desc="$2" detail="$3"
  if [[ "$STRICT" == true ]]; then
    print_fail "$rule_id" "$desc" "$detail"
    return
  fi
  ((WARN_COUNT++))
  ((TOTAL_COUNT++))
  if [[ "$JSON_OUTPUT" == true ]]; then
    JSON_RESULTS+=("{\"rule\":\"$rule_id\",\"status\":\"WARN\",\"description\":\"$desc\",\"detail\":\"$detail\"}")
  else
    printf "${YELLOW}[WARN]${RESET} %-45s ${CYAN}(%s)${RESET}\n" "$rule_id: $desc" "$detail"
  fi
}

print_fail() {
  local rule_id="$1" desc="$2" detail="$3"
  ((FAIL_COUNT++))
  ((TOTAL_COUNT++))
  if [[ "$JSON_OUTPUT" == true ]]; then
    JSON_RESULTS+=("{\"rule\":\"$rule_id\",\"status\":\"FAIL\",\"description\":\"$desc\",\"detail\":\"$detail\"}")
  else
    printf "${RED}[FAIL]${RESET} %-45s ${CYAN}(%s)${RESET}\n" "$rule_id: $desc" "$detail"
  fi
}

print_skip() {
  local rule_id="$1" desc="$2" detail="$3"
  ((SKIP_COUNT++))
  ((TOTAL_COUNT++))
  if [[ "$JSON_OUTPUT" == true ]]; then
    JSON_RESULTS+=("{\"rule\":\"$rule_id\",\"status\":\"SKIP\",\"description\":\"$desc\",\"detail\":\"$detail\"}")
  else
    printf "${CYAN}[SKIP]${RESET} %-45s ${CYAN}(%s)${RESET}\n" "$rule_id: $desc" "$detail"
  fi
}

# --- File discovery ---
declare -a CLAUDE_MD_FILES=()
MEMORY_MD_FILE=""

discover_files() {
  # Walk up from project root to find CLAUDE.md files
  local dir="$PROJECT_ROOT"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/CLAUDE.md" ]]; then
      CLAUDE_MD_FILES+=("$dir/CLAUDE.md")
    fi
    if [[ -f "$dir/.claude/CLAUDE.md" ]]; then
      CLAUDE_MD_FILES+=("$dir/.claude/CLAUDE.md")
    fi
    dir="$(dirname "$dir")"
  done

  # Check user-level CLAUDE.md
  if [[ -f "$HOME/.claude/CLAUDE.md" ]]; then
    # Avoid duplicates
    local already_found=false
    for f in "${CLAUDE_MD_FILES[@]}"; do
      if [[ "$f" == "$HOME/.claude/CLAUDE.md" ]]; then
        already_found=true
        break
      fi
    done
    if [[ "$already_found" == false ]]; then
      CLAUDE_MD_FILES+=("$HOME/.claude/CLAUDE.md")
    fi
  fi

  # Discover MEMORY.md files
  for memfile in "$HOME"/.claude/projects/*/memory/MEMORY.md; do
    if [[ -f "$memfile" ]]; then
      MEMORY_MD_FILE="$memfile"
      break  # Use the first match (project-specific)
    fi
  done
}

# --------------------------------------------------------------------------
# Rule 1: CLAUDE.md Line Count (HARD LIMIT)
# Severity: FAIL
# Source: https://docs.anthropic.com/en/docs/claude-code/memory
# Rationale: "Size: target under 200 lines per CLAUDE.md file. Longer files
#            consume more context and reduce adherence."
# Additional: "Files over 200 lines consume more context and may reduce
#            adherence. Move detailed content into separate files referenced
#            with @path imports, or split your instructions across
#            .claude/rules/ files."
# --------------------------------------------------------------------------
check_rule_1() {
  local file="$1"
  local lines
  lines=$(wc -l < "$file" | tr -d ' ')
  local relpath="${file#"$PROJECT_ROOT"/}"
  if [[ "$lines" -gt 200 ]]; then
    print_fail "Rule 1" "CLAUDE.md line count <= 200" "$relpath: $lines lines"
    return 1
  else
    print_pass "Rule 1" "CLAUDE.md line count <= 200" "$relpath: $lines lines"
    return 0
  fi
}

# --------------------------------------------------------------------------
# Rule 2: CLAUDE.md Character Count (RUNTIME WARNING THRESHOLD)
# Severity: WARN
# Source (runtime behavior): https://github.com/anthropics/claude-code
# Source (community confirmation): https://github.com/anthropics/claude-code/issues/2766
# Rationale: Claude Code emits "Large CLAUDE.md will impact performance
#            (Xk chars > 40.0k)" at runtime when combined CLAUDE.md content
#            exceeds 40,000 characters. This is an implementation-level
#            threshold in the Claude Code client, not a documented hard limit.
#            We enforce it as a warning for parity with the tool's own behavior.
# --------------------------------------------------------------------------
check_rule_2() {
  local total_chars=0
  for file in "${CLAUDE_MD_FILES[@]}"; do
    local chars
    chars=$(wc -m < "$file" | tr -d ' ')
    total_chars=$((total_chars + chars))
  done
  if [[ "$total_chars" -gt 40000 ]]; then
    print_warn "Rule 2" "Combined char count <= 40,000" "total: $total_chars chars"
    return 1
  else
    print_pass "Rule 2" "Combined char count <= 40,000" "total: $total_chars chars"
    return 0
  fi
}

# --------------------------------------------------------------------------
# Rule 3: MEMORY.md Line Count (HARD LIMIT)
# Severity: FAIL
# Source: https://docs.anthropic.com/en/docs/claude-code/memory
# Rationale: "The first 200 lines of MEMORY.md, or the first 25KB, whichever
#            comes first, are loaded at the start of every conversation.
#            Content beyond that threshold is not loaded at session start."
# --------------------------------------------------------------------------
check_rule_3() {
  if [[ -z "$MEMORY_MD_FILE" ]]; then
    print_skip "Rule 3" "MEMORY.md line count <= 200" "not found -- skipped"
    return 0
  fi
  local lines
  lines=$(wc -l < "$MEMORY_MD_FILE" | tr -d ' ')
  if [[ "$lines" -gt 200 ]]; then
    print_fail "Rule 3" "MEMORY.md line count <= 200" "$MEMORY_MD_FILE: $lines lines"
    return 1
  else
    print_pass "Rule 3" "MEMORY.md line count <= 200" "$MEMORY_MD_FILE: $lines lines"
    return 0
  fi
}

# --------------------------------------------------------------------------
# Rule 4: MEMORY.md Size (HARD LIMIT)
# Severity: FAIL
# Source: https://docs.anthropic.com/en/docs/claude-code/memory
# Rationale: "The first 200 lines of MEMORY.md, or the first 25KB, whichever
#            comes first, are loaded at the start of every conversation."
# --------------------------------------------------------------------------
check_rule_4() {
  if [[ -z "$MEMORY_MD_FILE" ]]; then
    print_skip "Rule 4" "MEMORY.md size <= 25 KB" "not found -- skipped"
    return 0
  fi
  local bytes
  bytes=$(wc -c < "$MEMORY_MD_FILE" | tr -d ' ')
  if [[ "$bytes" -gt 25600 ]]; then
    print_fail "Rule 4" "MEMORY.md size <= 25 KB" "$MEMORY_MD_FILE: $bytes bytes"
    return 1
  else
    print_pass "Rule 4" "MEMORY.md size <= 25 KB" "$MEMORY_MD_FILE: $bytes bytes"
    return 0
  fi
}

# --------------------------------------------------------------------------
# Rule 5: Structure Check -- Markdown Headers Present
# Severity: WARN
# Source: https://docs.anthropic.com/en/docs/claude-code/memory
# Rationale: "Structure: use markdown headers and bullets to group related
#            instructions. Claude scans structure the same way readers do:
#            organized sections are easier to follow than dense paragraphs."
# --------------------------------------------------------------------------
check_rule_5() {
  local file="$1"
  local relpath="${file#"$PROJECT_ROOT"/}"
  local header_count
  header_count=$(grep -cE '^\s{0,3}#{1,6} ' "$file" 2>/dev/null || echo "0")
  if [[ "$header_count" -eq 0 ]]; then
    print_warn "Rule 5" "Markdown headers present" "$relpath: 0 headers found"
    return 1
  else
    print_pass "Rule 5" "Markdown headers present" "$relpath: $header_count headers"
    return 0
  fi
}

# --------------------------------------------------------------------------
# Rule 6: Specificity Check -- Vague Instruction Patterns
# Severity: WARN
# Source: https://docs.anthropic.com/en/docs/claude-code/memory
# Rationale: "Specificity: write instructions that are concrete enough to
#            verify." The docs contrast "Format code properly" (bad) vs
#            "Use 2-space indentation" (good), and "Test your changes"
#            (bad) vs "Run npm test before committing" (good).
# --------------------------------------------------------------------------
check_rule_6() {
  local file="$1"
  local relpath="${file#"$PROJECT_ROOT"/}"
  local vague_patterns=(
    "format code properly"
    "test your changes"
    "follow best practices"
    "write clean code"
    "be consistent"
  )
  local found_lines=""
  for pattern in "${vague_patterns[@]}"; do
    local matches
    matches=$(grep -niF "$pattern" "$file" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
      found_lines+="$matches"$'\n'
    fi
  done
  if [[ -n "$found_lines" ]]; then
    local count
    count=$(echo "$found_lines" | grep -c . || echo "0")
    print_warn "Rule 6" "No vague instruction patterns" "$relpath: $count vague patterns found"
    if [[ "$JSON_OUTPUT" == false ]]; then
      echo "$found_lines" | sed 's/^/         /' | head -10
    fi
    return 1
  else
    print_pass "Rule 6" "No vague instruction patterns" "$relpath: clean"
    return 0
  fi
}

# --------------------------------------------------------------------------
# Rule 7: Split Recommendation -- Large Files Should Use Imports
# Severity: WARN
# Source: https://docs.anthropic.com/en/docs/claude-code/memory
# Rationale: "If your instructions are growing large, split them using
#            imports or .claude/rules/ files."
# --------------------------------------------------------------------------
check_rule_7() {
  local file="$1"
  local relpath="${file#"$PROJECT_ROOT"/}"
  local lines
  lines=$(wc -l < "$file" | tr -d ' ')

  if [[ "$lines" -le 150 ]]; then
    print_pass "Rule 7" "Large file should use imports" "$relpath: $lines lines (under threshold)"
    return 0
  fi

  # Check for @import directives
  local has_import
  has_import=$(grep -c '@import\|@path' "$file" 2>/dev/null || echo "0")

  # Check for .claude/rules/ directory
  local has_rules_dir=false
  if [[ -d "$PROJECT_ROOT/.claude/rules" ]]; then
    has_rules_dir=true
  fi

  if [[ "$has_import" -gt 0 ]] || [[ "$has_rules_dir" == true ]]; then
    print_pass "Rule 7" "Large file should use imports" "$relpath: $lines lines, imports or rules/ present"
    return 0
  else
    print_warn "Rule 7" "Large file should use imports" "$relpath: $lines lines, no @import or .claude/rules/"
    return 1
  fi
}

# --- Fix mode for Rule 7 ---
fix_rule_7() {
  local file="$1"
  echo ""
  echo "${BOLD}Fix for Rule 7:${RESET} Create .claude/rules/ directory structure?"
  echo "This will:"
  echo "  1. Create .claude/rules/ directory"
  echo "  2. Create a placeholder .claude/rules/README.md"
  echo ""
  read -rp "Proceed? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy] ]]; then
    mkdir -p "$PROJECT_ROOT/.claude/rules"
    cat > "$PROJECT_ROOT/.claude/rules/README.md" << 'REOF'
# Claude Rules

Split large CLAUDE.md instructions into focused rule files in this directory.
Each `.md` file here is automatically loaded by Claude Code.

See: https://docs.anthropic.com/en/docs/claude-code/memory
REOF
    echo "${GREEN}Created .claude/rules/ with README.md${RESET}"
    echo "Move sections from your CLAUDE.md into separate files here."
  else
    echo "Skipped."
  fi
}

# --- Install mode ---
# Installs the checker as:
#   1. A committed script at .github/scripts/check-claude-md.sh
#   2. A GitHub Actions workflow at .github/workflows/check-claude-md.yml
#   3. A Husky pre-commit hook entry
# Idempotent -- overwrites existing files with the latest version.
install_hooks() {
  local script_source="$0"
  local target_script="$PROJECT_ROOT/.github/scripts/check-claude-md.sh"
  local target_workflow="$PROJECT_ROOT/.github/workflows/check-claude-md.yml"
  local husky_dir="$PROJECT_ROOT/.husky"
  local precommit_file="$husky_dir/pre-commit"
  local hook_line='.github/scripts/check-claude-md.sh --strict --no-color'

  echo ""
  echo "${BOLD}Installing defense-in-depth checks...${RESET}"
  echo ""

  # --- 1. Copy script into repo ---
  mkdir -p "$PROJECT_ROOT/.github/scripts"
  cp "$script_source" "$target_script"
  chmod +x "$target_script"
  echo "${GREEN}[OK]${RESET} Installed script: .github/scripts/check-claude-md.sh"

  # --- 2. Create GitHub Actions workflow ---
  mkdir -p "$PROJECT_ROOT/.github/workflows"
  cat > "$target_workflow" << 'WFEOF'
# ==========================================================================
# CLAUDE.md Compliance Check -- GitHub Actions
#
# Runs on every PR and push to main/master to ensure CLAUDE.md and MEMORY.md
# files comply with Anthropic's documented recommendations.
#
# Source: https://docs.anthropic.com/en/docs/claude-code/memory
# ==========================================================================
name: CLAUDE.md Compliance

on:
  pull_request:
    paths:
      - 'CLAUDE.md'
      - '.claude/**'
      - '**/.claude/**'
      - '**/CLAUDE.md'
  push:
    branches: [main, master]
    paths:
      - 'CLAUDE.md'
      - '.claude/**'
      - '**/.claude/**'
      - '**/CLAUDE.md'

permissions:
  contents: read

jobs:
  check-claude-md:
    name: Validate CLAUDE.md compliance
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Run CLAUDE.md compliance checker
        run: bash .github/scripts/check-claude-md.sh --strict --no-color
WFEOF
  echo "${GREEN}[OK]${RESET} Installed workflow: .github/workflows/check-claude-md.yml"

  # --- 3. Install Husky pre-commit hook ---
  # Check if Husky is set up in the project
  if [[ -d "$husky_dir" ]]; then
    # Husky directory exists -- add our hook if not already present
    if [[ -f "$precommit_file" ]]; then
      if grep -qF "$hook_line" "$precommit_file" 2>/dev/null; then
        echo "${CYAN}[OK]${RESET} Husky pre-commit already contains claude-md check (no change)"
      else
        # Append our check. Run only if CLAUDE.md files are staged.
        cat >> "$precommit_file" << HOOKEOF

# CLAUDE.md compliance check -- defense in depth
# Source: https://docs.anthropic.com/en/docs/claude-code/memory
if git diff --cached --name-only | grep -qE '(^|/)\.?claude|CLAUDE\.md'; then
  $hook_line
fi
HOOKEOF
        echo "${GREEN}[OK]${RESET} Added claude-md check to existing .husky/pre-commit"
      fi
    else
      # No pre-commit file yet -- create one
      cat > "$precommit_file" << HOOKEOF
#!/usr/bin/env sh

# CLAUDE.md compliance check -- defense in depth
# Source: https://docs.anthropic.com/en/docs/claude-code/memory
if git diff --cached --name-only | grep -qE '(^|/)\.?claude|CLAUDE\.md'; then
  $hook_line
fi
HOOKEOF
      chmod +x "$precommit_file"
      echo "${GREEN}[OK]${RESET} Created .husky/pre-commit with claude-md check"
    fi
  else
    # No Husky directory -- offer to initialize
    echo "${YELLOW}[WARN]${RESET} No .husky/ directory found."
    echo "  To add the pre-commit hook manually, ensure Husky is installed:"
    echo "    npx husky init"
    echo "  Then re-run with --install, or add this to .husky/pre-commit:"
    echo ""
    echo "    # CLAUDE.md compliance check"
    echo "    if git diff --cached --name-only | grep -qE '(^|/)\.?claude|CLAUDE\.md'; then"
    echo "      $hook_line"
    echo "    fi"
    echo ""
  fi

  echo ""
  echo "${BOLD}Install complete.${RESET} Files to commit:"
  echo "  git add .github/scripts/check-claude-md.sh .github/workflows/check-claude-md.yml"
  if [[ -d "$husky_dir" ]]; then
    echo "  git add .husky/pre-commit"
  fi
  echo ""
}

# --- Usage ---
print_help() {
  cat << 'HELPEOF'
Usage: check-claude-md.sh [project_root] [OPTIONS]

Validate CLAUDE.md and MEMORY.md files against Anthropic's official recommendations.

Options:
  --strict     Promote all WARNs to FAILs
  --json       Output results as a JSON array
  --fix        Eagerly fix all failures (section extraction, rewrites, scaffolding)
  --install    Install as GitHub Action + Husky pre-commit hook (idempotent)
  --no-color   Disable color output
  --help       Show this help message

Rules enforced:
  Rule 1: CLAUDE.md line count <= 200 per file          [FAIL]
  Rule 2: Combined CLAUDE.md char count <= 40,000        [WARN]
  Rule 3: MEMORY.md line count <= 200                    [FAIL]
  Rule 4: MEMORY.md byte size <= 25 KB                   [FAIL]
  Rule 5: Markdown headers present in CLAUDE.md          [WARN]
  Rule 6: No vague instruction anti-patterns             [WARN]
  Rule 7: Large files (>150 lines) should use imports    [WARN]

All rules cite exact Anthropic documentation URLs.
Source: https://docs.anthropic.com/en/docs/claude-code/memory

Exit codes:
  0 -- All checks passed (warnings may have been emitted)
  1 -- One or more FAIL-severity checks did not pass
HELPEOF
}

# --- Argument parsing ---
parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --strict) STRICT=true ;;
      --json) JSON_OUTPUT=true ;;
      --fix) FIX_MODE=true ;;
      --install) INSTALL_MODE=true ;;
      --no-color) NO_COLOR=true ;;
      --help) print_help; exit 0 ;;
      -*)
        echo "Unknown option: $arg" >&2
        echo "Run with --help for usage." >&2
        exit 1
        ;;
      *)
        if [[ -z "$PROJECT_ROOT" ]]; then
          PROJECT_ROOT="$arg"
        fi
        ;;
    esac
  done
  if [[ -z "$PROJECT_ROOT" ]]; then
    PROJECT_ROOT="$(pwd)"
  fi
  PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
}

# --- Main ---
main() {
  parse_args "$@"
  init_colors
  discover_files

  if [[ "$JSON_OUTPUT" == false ]]; then
    echo ""
    echo "${BOLD}CLAUDE.md Compliance Check -- $PROJECT_ROOT${RESET}"
    printf '%.0s═' {1..60}
    echo ""
    echo ""
  fi

  # Rule 1: Per-file line count
  if [[ ${#CLAUDE_MD_FILES[@]} -eq 0 ]]; then
    print_skip "Rule 1" "CLAUDE.md line count <= 200" "no CLAUDE.md files found"
  else
    for file in "${CLAUDE_MD_FILES[@]}"; do
      check_rule_1 "$file" || true
    done
  fi

  # Rule 2: Combined character count
  if [[ ${#CLAUDE_MD_FILES[@]} -eq 0 ]]; then
    print_skip "Rule 2" "Combined char count <= 40,000" "no CLAUDE.md files found"
  else
    check_rule_2 || true
  fi

  # Rule 3: MEMORY.md line count
  check_rule_3 || true

  # Rule 4: MEMORY.md size
  check_rule_4 || true

  # Rule 5: Headers per file
  if [[ ${#CLAUDE_MD_FILES[@]} -eq 0 ]]; then
    print_skip "Rule 5" "Markdown headers present" "no CLAUDE.md files found"
  else
    for file in "${CLAUDE_MD_FILES[@]}"; do
      check_rule_5 "$file" || true
    done
  fi

  # Rule 6: Vague patterns per file
  if [[ ${#CLAUDE_MD_FILES[@]} -eq 0 ]]; then
    print_skip "Rule 6" "No vague instruction patterns" "no CLAUDE.md files found"
  else
    for file in "${CLAUDE_MD_FILES[@]}"; do
      check_rule_6 "$file" || true
    done
  fi

  # Rule 7: Split recommendation per file
  local rule7_fixable_files=()
  if [[ ${#CLAUDE_MD_FILES[@]} -eq 0 ]]; then
    print_skip "Rule 7" "Large file should use imports" "no CLAUDE.md files found"
  else
    for file in "${CLAUDE_MD_FILES[@]}"; do
      if ! check_rule_7 "$file"; then
        rule7_fixable_files+=("$file")
      fi
    done
  fi

  # Fix mode
  if [[ "$FIX_MODE" == true ]] && [[ ${#rule7_fixable_files[@]} -gt 0 ]]; then
    for file in "${rule7_fixable_files[@]}"; do
      fix_rule_7 "$file"
    done
  fi

  # Install mode -- runs after checks so you see current state first
  if [[ "$INSTALL_MODE" == true ]]; then
    install_hooks
  fi

  # Output
  if [[ "$JSON_OUTPUT" == true ]]; then
    echo "["
    local first=true
    for result in "${JSON_RESULTS[@]}"; do
      if [[ "$first" == true ]]; then
        first=false
      else
        echo ","
      fi
      echo "  $result"
    done
    echo ""
    echo "]"
  else
    echo ""
    printf '%.0s─' {1..60}
    echo ""
    echo "${BOLD}Summary:${RESET} $TOTAL_COUNT checks | ${GREEN}$PASS_COUNT passed${RESET} | ${YELLOW}$WARN_COUNT warnings${RESET} | ${RED}$FAIL_COUNT failed${RESET} | $SKIP_COUNT skipped"
    echo ""
  fi

  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
```

Run this script with:

```bash
bash /tmp/check-claude-md.sh "$PROJECT_ROOT" $FLAGS
```

Where `$PROJECT_ROOT` is the current working directory and `$FLAGS` are the parsed arguments from the user.

---

## Post-Execution

After the script runs, display its output to the user as-is (the script handles formatting).

### If `--install` was used

Remind the user to commit the new files:

- `.github/scripts/check-claude-md.sh` -- the checker script, committed into the repo
- `.github/workflows/check-claude-md.yml` -- GitHub Action that runs on PRs touching CLAUDE.md files
- `.husky/pre-commit` -- pre-commit hook (only if Husky was already initialized)
- Explain: the GH Action uses `--strict --no-color` so warnings become CI failures. The pre-commit hook only fires when staged files match CLAUDE.md patterns, keeping unrelated commits fast.

### If all checks passed (no `--fix`)

Print a clean confirmation. Done.

### If checks failed and `--fix` was NOT used

Suggest specific remediation for each failed rule but do not modify files.

### If `--fix` was used -- Eager Fix Mode

This is the core remediation workflow. The bash script handles detection; this phase uses Claude's tools to do the intelligent refactoring. Fix ALL failing rules, not just Rule 7.

**Important:** The `--fix` flag in the bash script itself only handles the Rule 7 `.claude/rules/` scaffold. The broader eager-fix logic below runs as the skill's post-execution phase using Read, Edit, Write, and AskUserQuestion tools.

#### Step 1: Triage failures

Read the script output and categorize failures:

| Failure                         | Fix Strategy                                      |
| ------------------------------- | ------------------------------------------------- |
| Rule 1 (line count > 200)       | Section extraction -- relocate reference material |
| Rule 2 (char count > 40k)       | Same as Rule 1, applied across all files          |
| Rule 3 (MEMORY.md lines > 200)  | Consolidate and compress memory entries           |
| Rule 4 (MEMORY.md bytes > 25KB) | Same as Rule 3                                    |
| Rule 5 (no headers)             | Add markdown structure                            |
| Rule 6 (vague patterns)         | Rewrite vague instructions to be concrete         |
| Rule 7 (large, no imports)      | Create `.claude/rules/` and split                 |

#### Step 2: Present the fix plan

Use **AskUserQuestion** to present a numbered list of proposed changes. Example:

> Here's the fix plan for 3 failing rules:
>
> 1. **Rule 1 -- CLAUDE.md is 287 lines (limit: 200)**
>    - Move "## Architecture" (lines 45-112) → `.context/architecture.md`
>    - Move "## API Patterns" (lines 113-198) → `.context/api-patterns.md`
>    - Leave 2-line pointers: `See .context/architecture.md` and `See .context/api-patterns.md`
>    - Result: ~118 lines remaining
> 2. **Rule 6 -- 2 vague patterns found**
>    - Line 23: "Follow best practices" → "Run `npm run lint && npm run typecheck` before committing"
>    - Line 67: "Test your changes" → "Run `npm test` and ensure all tests pass before pushing"
> 3. **Rule 7 -- No .claude/rules/ or imports**
>    - Create `.claude/rules/` directory
>
> Proceed with all fixes? (yes / pick numbers / no)

If the user picks specific numbers, only apply those.

#### Step 3: Fix Rule 1 / Rule 2 -- Section Extraction

This is the most complex fix. For each oversized CLAUDE.md:

**3A. Analyze sections.** Read the file and parse it into sections by markdown headers (`#`, `##`, `###`). For each section, classify it:

| Classification | Criteria                                                                                                  | Action                                |
| -------------- | --------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| **Directive**  | Short, imperative instructions. Commands like "always", "never", "use X". Under 10 lines.                 | KEEP in CLAUDE.md                     |
| **Reference**  | Detailed explanations, architecture docs, API patterns, examples, tables > 5 rows, code blocks > 5 lines. | RELOCATE                              |
| **Convention** | Style rules, naming patterns, file organization rules.                                                    | Keep if short, relocate if > 15 lines |

**3B. Choose relocation targets.** Follow established patterns in the repo:

1. **If `.context/` exists** -- use it. Create domain-named files:
   - Architecture docs → `.context/architecture.md`
   - API patterns → `.context/api-patterns.md`
   - Database conventions → `.context/database.md`
   - Testing guidelines → `.context/testing.md`
   - General reference → `.context/conventions.md`

2. **If `.claude/rules/` exists** -- use it for convention-type content:
   - Code style rules → `.claude/rules/code-style.md`
   - Git workflow → `.claude/rules/git-workflow.md`
   - PR conventions → `.claude/rules/pr-conventions.md`
     Note: `.claude/rules/*.md` files are auto-loaded by Claude Code, so they don't need explicit pointers.

3. **If neither exists** -- create `.context/` for reference material and `.claude/rules/` for conventions. Prefer `.claude/rules/` for anything Claude should always see (it's auto-loaded). Use `.context/` for deeper reference material that Claude can read on demand.

**3C. Extract and relocate.** For each section being relocated:

1. Read the section content from CLAUDE.md
2. Write it to the target file with a header comment:
   ```markdown
   <!-- Extracted from CLAUDE.md by /pst:claude-md --fix -->
   <!-- Source: https://docs.anthropic.com/en/docs/claude-code/memory -->
   ```
3. Replace the section in CLAUDE.md with a compact pointer:
   - For `.context/` files: `- See [Section Name](.context/filename.md) for details`
   - For `.claude/rules/` files: _(no pointer needed -- auto-loaded by Claude Code)_. Just remove the section and note in a comment: `<!-- Moved to .claude/rules/filename.md (auto-loaded) -->`

**3D. Verify budget.** After all extractions, count the remaining lines. If still over 200:

- Look for more sections to extract (lower the "short" threshold)
- Compress remaining content: convert paragraphs to bullet points, remove redundant phrasing
- If still over 200 after compression, use **AskUserQuestion**: "CLAUDE.md is still at N lines after extraction. Which remaining sections should I trim or relocate?"

#### Step 4: Fix Rule 3 / Rule 4 -- MEMORY.md Compression

For oversized MEMORY.md:

1. Read all memory entries (each entry is a line in the index with a pointer to a `.md` file)
2. Identify stale or redundant entries:
   - Entries about files/functions that no longer exist (verify with Glob/Grep)
   - Duplicate or overlapping entries
   - Entries that state things already in CLAUDE.md or code
3. Remove stale entries (delete both the index line and the memory file)
4. For remaining entries over the limit, consolidate related entries into fewer files
5. Rewrite the MEMORY.md index to be more compact (shorter descriptions)

#### Step 5: Fix Rule 5 -- Add Structure

If a CLAUDE.md has no headers:

1. Read the content
2. Identify logical groupings (blank lines, topic changes)
3. Add appropriate `##` headers
4. Rewrite with Edit tool

#### Step 6: Fix Rule 6 -- Replace Vague Patterns

For each vague pattern found:

1. Read surrounding context to understand intent
2. Check `package.json` for available scripts (test, lint, build, format)
3. Replace the vague instruction with a concrete one:
   - "Format code properly" → "Run `npx prettier --write .` to format" (or project-specific formatter)
   - "Test your changes" → "Run `npm test` and ensure all tests pass"
   - "Follow best practices" → remove entirely, or replace with the specific practice intended
   - "Write clean code" → remove entirely (too vague to be actionable)
   - "Be consistent" → replace with the specific consistency rule (e.g., "Use named exports, not default exports")

#### Step 7: Fix Rule 7 -- Split Scaffold

If the bash script's `--fix` mode already created `.claude/rules/`, this step is done. Otherwise:

1. Create `.claude/rules/` directory
2. If Rule 1 extraction already moved convention content there, done
3. Otherwise create a placeholder README

#### Step 8: Re-validate

After all fixes are applied, **re-run the bash script** (without `--fix`) to confirm all rules now pass. Display the before/after comparison:

```
Before: 7 checks | 2 passed | 2 warnings | 3 failed
After:  7 checks | 5 passed | 2 warnings | 0 failed
```

If any rules still fail, report them and explain what manual intervention is needed.

#### Step 9: Summary

Print a manifest of all changes made:

```
FILES CREATED:
  .context/architecture.md          (67 lines, extracted from CLAUDE.md)
  .context/api-patterns.md          (85 lines, extracted from CLAUDE.md)
  .claude/rules/code-style.md       (12 lines, extracted from CLAUDE.md)

FILES MODIFIED:
  CLAUDE.md                         (287 → 142 lines)

FILES DELETED:
  (none)

Ready to commit:
  git add CLAUDE.md .context/ .claude/rules/
```
