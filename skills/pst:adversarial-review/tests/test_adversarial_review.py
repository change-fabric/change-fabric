"""Unit tests for the /pst:adversarial-review deterministic mechanics.

Covers the pure, side-effect-free half: slug derivation, path/manifest
resolution, idempotent scaffold writes, changelog parsing, branch suffix
bumping, and PR-body composition. No git / gh / code calls are made, so the
suite is fast and runs anywhere.

Run:  pytest skills/pst:adversarial-review/tests -q
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS))

import adversarial_review as ar  # noqa: E402


# --- slugify --------------------------------------------------------------- #


@pytest.mark.parametrize(
    "subject,expected",
    [
        ("a rate limiter for the public API", "a-rate-limiter-for-the-public-api"),
        ("Migrate auth to Better Auth", "migrate-auth-to-better-auth"),
        ("  Trim  & collapse---punctuation!! ", "trim-collapse-punctuation"),
        ("UPPER and MixedCase", "upper-and-mixedcase"),
        ("!!!", "untitled"),
        ("", "untitled"),
    ],
)
def test_slugify(subject, expected):
    assert ar.slugify(subject) == expected


def test_slugify_caps_length_and_trims_trailing_hyphen():
    s = ar.slugify("x" * 40 + " " + "y" * 40, max_len=50)
    assert len(s) <= 50
    assert not s.endswith("-")


# --- resolve_manifest ------------------------------------------------------ #


def test_resolve_manifest_uses_docs_when_present(tmp_path):
    m = ar.resolve_manifest(
        "Rate limiter", repo_root=tmp_path, base="main", has_docs=True
    )
    assert m.slug == "rate-limiter"
    assert m.workdir == str(tmp_path / "docs" / "plans" / "rate-limiter")
    assert m.branch == "feat/rate-limiter"
    assert m.base == "main"
    assert m.impl_dir == str(tmp_path / ".worktrees" / "rate-limiter")
    assert m.plan_path.endswith("PLAN.md")
    assert m.prompt_path.endswith("ADVERSARIAL-REVIEW-PROMPT.md")
    assert m.changelog_path.endswith("CHANGELOG.md")


def test_resolve_manifest_falls_back_outside_repo_without_docs(tmp_path):
    m = ar.resolve_manifest("Rate limiter", repo_root=tmp_path, base="main", has_docs=False)
    # Scratch dir must be outside the repo so plan files are not committed.
    assert str(tmp_path) not in m.workdir
    assert "adversarial-review" in m.workdir


def test_resolve_manifest_explicit_workdir_wins(tmp_path):
    wd = tmp_path / "custom"
    m = ar.resolve_manifest(
        "x", repo_root=tmp_path, base="dev", has_docs=True, workdir=wd
    )
    assert m.workdir == str(wd)
    assert m.base == "dev"


# --- scaffold writes (idempotency) ----------------------------------------- #


def _init(tmp_path, force=False):
    import argparse

    ns = argparse.Namespace(
        subject="Rate limiter",
        base="main",
        workdir=str(tmp_path / "wd"),
        repo_root=str(tmp_path),
        force=force,
        json=False,
    )
    return ns


def test_init_writes_three_artifacts(tmp_path, capsys):
    rc = ar.cmd_init(_init(tmp_path))
    assert rc == 0
    wd = tmp_path / "wd"
    for name in (ar.PLAN_NAME, ar.PROMPT_NAME, ar.CHANGELOG_NAME):
        assert (wd / name).exists()
    # Prompt carries the fill-in slot; plan carries section headers.
    assert ar.CONTEXT_SLOT in (wd / ar.PROMPT_NAME).read_text()
    assert "## Acceptance criteria" in (wd / ar.PLAN_NAME).read_text()


def test_init_is_idempotent_and_preserves_authored_content(tmp_path):
    ar.cmd_init(_init(tmp_path))
    plan = tmp_path / "wd" / ar.PLAN_NAME
    plan.write_text("# Plan: Rate limiter\n\nAUTHORED BODY\n", encoding="utf-8")
    # Re-running init must NOT clobber the model-authored plan.
    ar.cmd_init(_init(tmp_path))
    assert "AUTHORED BODY" in plan.read_text()


def test_init_force_overwrites(tmp_path):
    ar.cmd_init(_init(tmp_path))
    plan = tmp_path / "wd" / ar.PLAN_NAME
    plan.write_text("AUTHORED BODY\n", encoding="utf-8")
    ar.cmd_init(_init(tmp_path, force=True))
    assert "AUTHORED BODY" not in plan.read_text()
    assert "## Acceptance criteria" in plan.read_text()


# --- parse_changelog ------------------------------------------------------- #


def test_parse_changelog_basic_pairs():
    text = """# Changelog

- **What:** Tightened the scope to a single bucket.
  **Why:** A multi-bucket design risked race conditions on the counter.
- **What:** Added a rollback phase.
  **Why:** No way to revert the schema migration was a data-loss gap.
"""
    entries = ar.parse_changelog(text)
    assert len(entries) == 2
    assert entries[0].what == "Tightened the scope to a single bucket."
    assert "race conditions" in entries[0].why
    assert entries[1].what == "Added a rollback phase."


def test_parse_changelog_tolerates_formatting_variants():
    text = """What: no bullet, no bold
Why: still parsed

* **what**: lowercase bold marker
  why: lowercase why
"""
    entries = ar.parse_changelog(text)
    assert len(entries) == 2
    assert entries[0].what == "no bullet, no bold"
    assert entries[0].why == "still parsed"
    assert entries[1].what == "lowercase bold marker"
    assert entries[1].why == "lowercase why"


def test_parse_changelog_multiline_continuation():
    text = """- **What:** first line
  second line of what
  **Why:** first reason
  second line of reason
"""
    entries = ar.parse_changelog(text)
    assert len(entries) == 1
    assert entries[0].what == "first line second line of what"
    assert entries[0].why == "first reason second line of reason"


def test_parse_changelog_missing_why_is_flagged_empty():
    text = "- **What:** a change with no rationale\n"
    entries = ar.parse_changelog(text)
    assert len(entries) == 1
    assert entries[0].what == "a change with no rationale"
    assert entries[0].why == ""


def test_parse_changelog_empty_or_stub_returns_nothing():
    assert ar.parse_changelog("") == []
    stub = ar.render_changelog_stub("Rate limiter")
    assert ar.parse_changelog(stub) == []


# --- bump_branch ----------------------------------------------------------- #


def test_bump_branch_no_collision():
    assert ar.bump_branch("rate-limiter", lambda n: False) == "feat/rate-limiter"


def test_bump_branch_suffixes_on_collision():
    taken = {"feat/rate-limiter", "feat/rate-limiter-2"}
    assert ar.bump_branch("rate-limiter", lambda n: n in taken) == "feat/rate-limiter-3"


# --- compose_pr_body ------------------------------------------------------- #


def test_compose_pr_body_includes_paths_and_no_literal_newlines():
    body = ar.compose_pr_body("Rate limiter", "/p/PLAN.md", "/p/CHANGELOG.md")
    assert "Implements: Rate limiter" in body
    assert "/p/PLAN.md" in body
    assert "/p/CHANGELOG.md" in body
    assert "\\n" not in body  # real newlines, never escaped


# --- prompt / plan rendering ----------------------------------------------- #


def test_render_prompt_is_self_contained_and_slotted():
    p = ar.render_prompt("Rate limiter")
    assert ar.CONTEXT_SLOT in p
    assert "Attack the plan" in p
    assert "CHANGELOG.md" in p


def test_render_plan_skeleton_has_all_required_sections():
    plan = ar.render_plan_skeleton("Rate limiter")
    for header in (
        "## Subject / goal",
        "## Scope",
        "## Phases",
        "## Design options + recommendation",
        "## Risks & failure modes",
        "## Acceptance criteria",
        "## Open questions",
    ):
        assert header in plan
