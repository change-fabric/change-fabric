---
name: pst:python-refactor
description: Extract business logic from Python modules into tested, well-structured functions and classes -- enforce strict typing and pytest coverage
argument-hint: "[file-pattern | --all | --branch <name> | --dry-run]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, AskUserQuestion
---

# Python Refactor: Extract Business Logic + Tests

Extract business logic from monolithic Python modules, views, routes, and scripts into well-structured, tested modules. Enforces strict typing, pytest coverage, and clean architecture.

---

## Stage 1 - Input Parsing

<arguments> #$ARGUMENTS </arguments>

**Parse arguments:**

- File glob pattern (e.g., `src/services/dashboard.py`) -- refactor specific files
- `--all` -- scan entire project for modules with extractable business logic
- `--branch <name>` -- scope to files changed on the named branch vs the default branch
- `--dry-run` -- analysis only, no file modifications, print what would change

**Default behavior (no arguments):** Detect `.py` files changed on the current branch vs the default branch:

```bash
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
git diff --name-only "$DEFAULT_BRANCH"...HEAD -- '*.py'
```

If no `.py` files found on the branch, ask the user via AskUserQuestion what to target.

---

## Stage 2 - Project Detection

Detect the Python project type and tooling to tailor the refactoring approach.

**Project type detection** (check imports and project files):

| Signal                                      | Project type            |
| ------------------------------------------- | ----------------------- |
| `from django` / `django` in requirements    | Django                  |
| `from flask` / `flask` in requirements      | Flask                   |
| `from fastapi` / `fastapi` in requirements  | FastAPI                 |
| `import click` / `import typer`             | CLI app                 |
| `pyproject.toml` with `[tool.poetry]`       | Poetry project          |
| `setup.py` / `setup.cfg` / `pyproject.toml` | Standard Python package |
| None of the above                           | Script / library        |

**Tooling detection:**

```bash
# Package manager
if [ -f "pyproject.toml" ] && grep -q "poetry" pyproject.toml 2>/dev/null; then PKG="poetry run"; \
elif [ -f "Pipfile" ]; then PKG="pipenv run"; \
elif { [ -f "uv.lock" ] || [ -f "pyproject.toml" ]; } && command -v uv &>/dev/null; then PKG="uv run"; \
else PKG="python -m"; fi

# Test runner (always pytest -- unittest.TestCase only if project uses it pervasively per rule P5)
TEST_RUNNER="pytest"

# Type checker
if grep -rq "mypy" pyproject.toml setup.cfg requirements*.txt 2>/dev/null; then TYPE_CHECKER="mypy"; \
elif grep -rq "pyright" pyproject.toml requirements*.txt 2>/dev/null; then TYPE_CHECKER="pyright"; \
else TYPE_CHECKER="mypy"; fi  # default

# Linter
if grep -rq "ruff" pyproject.toml requirements*.txt 2>/dev/null; then LINTER="ruff"; \
elif grep -rq "flake8" pyproject.toml setup.cfg requirements*.txt 2>/dev/null; then LINTER="flake8"; \
else LINTER="ruff"; fi  # default
```

---

## Stage 3 - Refactoring Rules

These rules govern all refactoring decisions. They are **non-negotiable** unless the user explicitly overrides via AskUserQuestion.

### Structural rules

| #   | Rule                                                                                                                                                                                                       |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P1  | **Business logic out of views/routes/handlers.** Views should delegate to service functions or classes, not contain logic.                                                                                 |
| P2  | **Pure functions preferred.** Extract logic as pure functions (input -> output, no side effects) whenever possible. Only use classes when state management across multiple operations is genuinely needed. |
| P3  | **One module, one responsibility.** Each extracted module should have a single, clear purpose. Name it after what it does, not where it came from.                                                         |
| P4  | **Test files co-located or in parallel `tests/` tree.** Match the project's existing convention. If no convention exists, use a `tests/` directory mirroring the source structure.                         |
| P5  | **pytest exclusively.** No unittest.TestCase (unless the project already uses it pervasively). Use pytest fixtures, parametrize, and plain assert.                                                         |
| P6  | **Comprehensive test coverage:** every branch, edge case, error state, boundary value. Business logic bugs should be caught in unit tests, not integration tests.                                          |

### Type safety rules

| #   | Rule                                                                                                   |
| --- | ------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------- |
| T1  | **All function signatures fully typed.** Parameters and return types -- no exceptions.                 |
| T2  | **No `Any` type.** Use proper generics, `Union`, `Protocol`, or specific types.                        |
| T3  | **No `type: ignore` comments.** Fix the type error instead. If truly unavoidable, use AskUserQuestion. |
| T4  | **Use modern type syntax.** `list[str]` not `List[str]`, `str                                          | None`not`Optional[str]`(Python 3.10+). For older projects, use`from **future** import annotations`. |
| T5  | **Dataclasses or Pydantic for structured data.** No raw dicts for domain objects.                      |

### Code quality rules

| #   | Rule                                                                                                          |
| --- | ------------------------------------------------------------------------------------------------------------- |
| Q1  | **Named exports only.** Use `__all__` to declare public API in extracted modules.                             |
| Q2  | **No `noqa` comments.** Fix the lint violation. If truly unavoidable, use AskUserQuestion.                    |
| Q3  | **No bare `except`.** Always catch specific exceptions.                                                       |
| Q4  | **No mutable default arguments.** Use `None` with a sentinel pattern.                                         |
| Q5  | **Docstrings on public functions** only when the name and types don't fully convey intent. Skip obvious ones. |

---

## Stage 4 - Discovery

For each target `.py` file:

1. **Read** the module
2. **Classify** the module type:
   - View/route handler (Django view, Flask route, FastAPI endpoint)
   - Service/business logic module
   - Utility/helper module
   - CLI command
   - Script
   - Data model
3. **Identify extractable business logic:**
   - Data transformation, filtering, sorting, mapping
   - Validation logic
   - Business rule evaluation (conditional logic computing outcomes)
   - API call orchestration and response handling
   - Complex computations or algorithms
   - State machine logic
   - File/data parsing and formatting
4. **Skip** files where:
   - Logic already lives in service modules (view just delegates)
   - Module is purely declarative (models, schemas, config)
   - Logic is trivial (single validation, nothing to extract)

**Print discovery report:**

```
DISCOVERY REPORT
----------------
Files scanned: {N}
Candidates for refactoring: {M}
Skipped (already clean): {K}

  app/views/dashboard.py    - 3 extractable blocks (data transform, filtering, report generation)
  app/views/user.py         - 2 extractable blocks (validation, permission checks)
  app/views/settings.py     - SKIP (already delegates to services.settings)
```

**If `--dry-run`:** Stop here. Do not modify any files.

---

## Stage 5 - Refactoring

Process each candidate module. **If multiple candidates share imports or are in the same package, process them sequentially to avoid conflicting edits.** Only parallelize across independent packages.

```
Agent:
  description: "Refactor {ModuleName}: extract business logic"
```

**Sub-agent workflow per module:**

### 5a. Plan the Extraction

- Identify each block of business logic to extract
- Name the target module: prefer specific names (`dashboard_filters`, `user_validation`, `report_builder`) over generic ones (`dashboard_utils`, `helpers`)
- Define the public API: what functions/classes will be exported
- If a module has multiple unrelated concerns, create multiple target modules
- Decide placement: `services/`, `domain/`, `logic/`, or match existing project convention

### 5b. Create the Service/Logic Module

Create the extracted module in the appropriate location.

**Module rules:**

- Descriptive module name matching its responsibility
- `__all__` list declaring the public API
- All functions fully typed (parameters and return)
- Pure functions where possible -- no hidden side effects
- Dependencies injected as parameters, not imported globals
- Dataclasses or Pydantic models for structured inputs/outputs
- No `Any` types
- No `type: ignore` comments
- No `noqa` comments
- No bare `except`

**Example structure:**

```python
"""Dashboard filtering and sorting logic."""

from __future__ import annotations

__all__ = ["apply_filter", "sort_items", "DashboardItem", "FilterType", "SortOrder"]

from dataclasses import dataclass
from enum import Enum


class FilterType(Enum):
    ALL = "all"
    ACTIVE = "active"
    ARCHIVED = "archived"


class SortOrder(Enum):
    ASC = "asc"
    DESC = "desc"


@dataclass(frozen=True)
class DashboardItem:
    id: str
    name: str
    status: str
    created_at: str


def apply_filter(items: list[DashboardItem], filter_type: FilterType) -> list[DashboardItem]:
    if filter_type is FilterType.ALL:
        return items
    return [item for item in items if item.status == filter_type.value]


def sort_items(items: list[DashboardItem], order: SortOrder) -> list[DashboardItem]:
    reverse = order is SortOrder.DESC
    return sorted(items, key=lambda item: item.created_at, reverse=reverse)
```

### 5c. Update the Original Module

Replace inline business logic with imports from the extracted module. The view/route/handler should now be a thin layer that:

- Parses the request
- Calls service functions
- Returns the response

Remove extracted logic from the original module body.

### 5d. Create the Test File

Create tests co-located or in the `tests/` tree, matching project convention.

**Test file structure:**

```python
"""Tests for dashboard filtering and sorting logic."""

from __future__ import annotations

import pytest

from app.services.dashboard_filters import (
    DashboardItem,
    FilterType,
    SortOrder,
    apply_filter,
    sort_items,
)


@pytest.fixture
def sample_items() -> list[DashboardItem]:
    return [
        DashboardItem(id="1", name="Alpha", status="active", created_at="2024-01-01"),
        DashboardItem(id="2", name="Beta", status="archived", created_at="2024-01-02"),
        DashboardItem(id="3", name="Gamma", status="active", created_at="2024-01-03"),
    ]


class TestApplyFilter:
    def test_returns_all_items_when_filter_is_all(self, sample_items: list[DashboardItem]) -> None:
        result = apply_filter(sample_items, FilterType.ALL)
        assert result == sample_items

    def test_filters_by_active_status(self, sample_items: list[DashboardItem]) -> None:
        result = apply_filter(sample_items, FilterType.ACTIVE)
        assert len(result) == 2
        assert all(item.status == "active" for item in result)

    def test_returns_empty_list_for_empty_input(self) -> None:
        assert apply_filter([], FilterType.ACTIVE) == []


class TestSortItems:
    def test_sorts_ascending(self, sample_items: list[DashboardItem]) -> None:
        result = sort_items(sample_items, SortOrder.ASC)
        assert result[0].id == "1"
        assert result[-1].id == "3"

    def test_sorts_descending(self, sample_items: list[DashboardItem]) -> None:
        result = sort_items(sample_items, SortOrder.DESC)
        assert result[0].id == "3"
        assert result[-1].id == "1"

    def test_handles_empty_list(self) -> None:
        assert sort_items([], SortOrder.ASC) == []

    def test_handles_single_item(self) -> None:
        item = DashboardItem(id="1", name="Solo", status="active", created_at="2024-01-01")
        assert sort_items([item], SortOrder.ASC) == [item]
```

**Coverage targets:**

- Every branch in conditional logic
- Edge cases: empty collections, None inputs (where typed as optional), boundary values
- Error states: invalid inputs, expected exceptions
- All public functions exercised
- Parametrized tests for repetitive patterns

### 5e. Verify Tests Pass

```bash
$PKG pytest {test-file-path} -v 2>&1
```

If tests fail, fix the issue and re-run (max 3 attempts). If still failing after 3 attempts, report the failure and move to the next module.

---

## Stage 6 - Anti-Pattern Scan

After all refactoring, scan the modified and created files for anti-patterns:

Use dedicated tools (not shell equivalents):

- **Grep** for `noqa` in ALL modified and created files -- any match triggers the AskUserQuestion workflow
- **Grep** for `type: ignore` in all modified/created files -- violation
- **Grep** for `: Any` or `-> Any` in all modified/created files -- strict type safety violation
- **Grep** for `bare except:` (regex: `except\s*:`) in all files -- must catch specific exceptions
- **Grep** for `def .*\(.*=\[\]` or `def .*\(.*=\{\}` (mutable default args) in all files
- **Grep** for `from typing import.*List` or `from typing import.*Optional` in all files -- use modern syntax
- **Grep** for `import \*` in all files -- explicit imports only
- **Grep** for functions missing return type annotations (regex: `def \w+\([^)]*\)\s*:` without `->`)

Fix any violations found. For `noqa` findings, follow the AskUserQuestion workflow before taking action.

---

## Stage 7 - Architecture Codification

Check the **target repo** (not this skills repo) for existing documentation of the extraction pattern:

1. Look in: `CLAUDE.md`, `.claude/CLAUDE.md`, `.context/`, `docs/adr/`, `docs/decisions/`
2. Search for keywords: "service", "business logic", "extraction", "pure function", "architecture"

**If not documented**, create or append based on what exists:

- If the repo has `CLAUDE.md`: append a section
- If the repo has an ADR directory: create a new ADR following existing numbering
- If neither: create `CLAUDE.md` at the repo root

**Content to add:**

```markdown
## Architecture: Business Logic in Service Modules

- Business logic lives in service/domain modules, not in views/routes/handlers
- Pure functions preferred over classes -- use classes only when stateful operations are needed
- All function signatures fully typed (parameters and return types)
- No `Any` type -- use proper generics, Union, Protocol, or specific types
- Structured data uses dataclasses or Pydantic models, not raw dicts
- Tests use pytest with fixtures and parametrize
- `__all__` declares the public API of each module
- No `noqa` comments -- fix lint violations at the source
- No `type: ignore` -- fix type errors at the source
- No bare `except` -- catch specific exceptions
```

**If already documented:** Skip this stage.

---

## Stage 8 - Verification

Run full quality gates using the detected tooling from Stage 2:

| Check            | Command                                                                                                     |
| ---------------- | ----------------------------------------------------------------------------------------------------------- |
| Tests            | `$PKG pytest --tb=short`                                                                                    |
| Type check       | `$PKG $TYPE_CHECKER .` (or scoped to changed files)                                                         |
| Lint             | `$PKG $LINTER check .` (ruff) or `$PKG $LINTER .` (flake8)                                                  |
| Format           | `$PKG ruff format --check .` or `$PKG black --check .` (detect which is configured)                         |
| Type annotations | Grep all modified/created files for `: Any`, `-> Any`, `type: ignore` -- zero tolerance, fix all violations |

**Formatter detection:** Check `pyproject.toml` and config files for `ruff.format`, `black`, or `autopep8`. If no formatter is configured, skip the format check and note it in the summary.

If any gate fails: read the error, fix the issue, re-run all gates from the top (max 3 fix cycles). If a tool is not installed, skip it and note.

---

## Stage 9 - Summary Report

```
PYTHON REFACTOR COMPLETE
------------------------
Modules processed:    {N}
Modules created:      {M}
Test files created:   {K}
Tests passing:        {X}/{Y}
Architecture doc:     {created | updated | already present}
Quality gates:        {ALL PASSED | FAILED -- see above}
Type checker:         {mypy CLEAN | pyright CLEAN | NOT CHECKED -- not installed}
Linter:               {ruff CLEAN | flake8 CLEAN | NOT CHECKED -- not installed}
Formatter:            {COMPLIANT | NOT CHECKED -- no formatter config}
Type safety:          {CLEAN | N violations -- see above}

Framework detected:   {Django | Flask | FastAPI | CLI | library | script}
Test runner:          pytest
Package manager:      {poetry | pipenv | uv | pip}

Files created:
  app/services/dashboard_filters.py
  tests/services/test_dashboard_filters.py
  ...

Files modified:
  app/views/dashboard.py
  ...
```

---

## Error Handling

| Condition                                         | Action                                                                                                                                                                                             |
| ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| No `.py` files found in scope                     | Exit with message: "No Python files found in scope."                                                                                                                                               |
| pytest not installed                              | Log: `"pytest not found. Install: pip install pytest"` and abort                                                                                                                                   |
| Extraction is ambiguous (unclear what to extract) | Ask user via AskUserQuestion                                                                                                                                                                       |
| Test failures after 3 fix attempts                | Report the failing tests, continue to next module                                                                                                                                                  |
| Quality gate failures after 3 cycles              | Report and stop                                                                                                                                                                                    |
| Module has no extractable logic                   | Skip and note in discovery report                                                                                                                                                                  |
| `noqa` appears necessary during refactoring       | MUST use AskUserQuestion -- present the lint error, the code context, and 3 options: (1) fix the code, (2) adjust lint config, (3) suppress with comment. Default recommendation is option 1 or 2. |
| `type: ignore` appears necessary                  | Same AskUserQuestion workflow as `noqa`                                                                                                                                                            |
| Type checker not installed                        | Skip type check, note in summary report                                                                                                                                                            |
| Formatter not configured                          | Skip format check, note in summary report                                                                                                                                                          |
