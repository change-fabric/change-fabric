#!/usr/bin/env python3
"""Deterministic mechanics for the /pst:adversarial-review skill.

The skill's creative work (authoring the PLAN body, the prompt's Context
paragraph, the actual implementation, reconciling a returned changelog into code
edits) stays with the model. Everything mechanical, repetitive, or error-prone
lives here so it is fast, predictable, and idempotent:

  init            derive slug/paths/branch, scaffold the three artifacts (only
                  the parts that are fixed), and print a JSON manifest
  open            open the three artifacts in VS Code (code / code -r)
  start-impl      create an isolated worktree + branch off the base (idempotent;
                  bumps a numeric suffix on collision), print JSON
  pr              push the branch and open a draft PR (idempotent; reuses an
                  existing PR for the branch), print JSON
  parse-changelog parse a reviewer-written CHANGELOG.md into structured entries

The division of labor mirrors /plan-io: this builder owns assembly + IO +
idempotency; the model owns semantics. Scaffolds are written with slot markers
({{CONTEXT}} in the prompt, "_(fill in...)_" in the plan) that the model fills
in afterward via its editor; existing files are never clobbered unless --force
is passed, so re-running init is always safe.

Usage:
  adversarial_review.py init "<subject>" [--base BR] [--workdir DIR] [--force] [--json]
  adversarial_review.py open --workdir DIR
  adversarial_review.py start-impl --slug SLUG [--base BR] [--repo-root DIR] [--json]
  adversarial_review.py pr --slug SLUG --subject S --workdir DIR [--base BR] [--repo-root DIR] [--no-open] [--json]
  adversarial_review.py parse-changelog <path|-> [--json]

Stdlib only; no third-party deps. Python 3.9+.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Callable, Optional

PLAN_NAME = "PLAN.md"
PROMPT_NAME = "ADVERSARIAL-REVIEW-PROMPT.md"
CHANGELOG_NAME = "CHANGELOG.md"
CONTEXT_SLOT = "{{CONTEXT}}"
_FILL = "_(fill in)_"

# --------------------------------------------------------------------------- #
# Pure logic (unit-tested; no side effects)                                    #
# --------------------------------------------------------------------------- #


def slugify(subject: str, *, max_len: int = 50) -> str:
    """Lowercase, collapse non-alphanumerics to single hyphens, trim, cap length.

    Matches the bash the skill used to inline, so existing working dirs and
    branch names stay stable across the migration.
    """
    s = subject.strip().lower()
    s = re.sub(r"[^a-z0-9]+", "-", s)
    s = s.strip("-")
    s = s[:max_len].rstrip("-")
    return s or "untitled"


@dataclass
class Manifest:
    subject: str
    slug: str
    repo_root: str
    workdir: str
    plan_path: str
    prompt_path: str
    changelog_path: str
    branch: str
    base: str
    impl_dir: str
    context_slot: str = CONTEXT_SLOT
    created: list = field(default_factory=list)
    skipped: list = field(default_factory=list)

    def to_json(self) -> str:
        return json.dumps(asdict(self), indent=2)


def resolve_manifest(
    subject: str,
    *,
    repo_root: Path,
    base: str,
    has_docs: bool,
    workdir: Optional[Path] = None,
) -> Manifest:
    """Derive every path/name from the subject + repo, without touching disk.

    When ``has_docs`` is true the working dir defaults to
    ``<repo>/docs/plans/<slug>``; otherwise it falls back to a scratch dir
    outside the repo so plan files are not accidentally committed. An explicit
    ``workdir`` overrides both.
    """
    slug = slugify(subject)
    if workdir is None:
        if has_docs:
            workdir = repo_root / "docs" / "plans" / slug
        else:
            import tempfile

            workdir = Path(tempfile.gettempdir()) / "adversarial-review" / slug
    return Manifest(
        subject=subject,
        slug=slug,
        repo_root=str(repo_root),
        workdir=str(workdir),
        plan_path=str(workdir / PLAN_NAME),
        prompt_path=str(workdir / PROMPT_NAME),
        changelog_path=str(workdir / CHANGELOG_NAME),
        branch=f"feat/{slug}",
        base=base,
        impl_dir=str(repo_root / ".worktrees" / slug),
    )


def render_plan_skeleton(subject: str) -> str:
    """Headers-only plan. The model fills each section body via its editor."""
    return f"""# Plan: {subject}

> Scaffold written by `adversarial_review.py`. Fill each section below, then hand
> `{PROMPT_NAME}` to an adversarial reviewer. Do not delete the section headers.

## Subject / goal

{_FILL}

## Scope

**In scope**

- {_FILL}

**Out of scope**

- {_FILL}

## Phases

> Each phase: objective, concrete tasks, files touched, and churn risk
> (low/medium/high). Build lowest-churn phases first.

1. {_FILL}

## Design options + recommendation

> At least two viable approaches with tradeoffs, then a clear recommendation.

{_FILL}

## Risks & failure modes

> Correctness, security, performance, data loss, scope, ops -- each with a
> mitigation.

- {_FILL}

## Acceptance criteria

- [ ] {_FILL}

## Open questions

- {_FILL}
"""


def render_prompt() -> str:
    """Self-contained adversarial-review prompt with a Context slot to fill."""
    return f"""# Adversarial review request

You are an adversarial reviewer. Your job is to find everything wrong with the
plan in `{PLAN_NAME}` (in this same directory) and make it materially better.

## Context (self-contained -- assume no other knowledge of this project)

{CONTEXT_SLOT}

> Replace the line above with: what the project is, the relevant stack,
> constraints, and the goal (from the plan's Subject section). Spell out enough
> that the reviewer needs nothing else.

## What to do

1. **Attack the plan.** Find failure modes, hidden assumptions, security and
   correctness risks, scope problems (creep AND gaps), missing edge cases, race
   conditions, and operational/rollback gaps. Assume it is wrong until proven.
2. **Edit `{PLAN_NAME}` inline.** Apply concrete improvements directly in the
   file -- tighten scope, fix design choices, add phases/risks/acceptance
   criteria as needed. Do not write a separate review document; improve the plan
   itself.
3. **Write `{CHANGELOG_NAME}`.** For every change you made, append one entry:
   - **What:** the concrete change (section + before -> after in a sentence).
   - **Why:** the rationale -- the risk it removes or the gap it fills. A change
     with no rationale is not allowed. Order entries most-impactful first.

## Output

- An edited `{PLAN_NAME}` (improved in place).
- A populated `{CHANGELOG_NAME}` (one rationale-bearing entry per change).
- A 3-5 bullet summary of the most serious problems you found.
"""


def render_changelog_stub(subject: str) -> str:
    return f"""# Changelog -- adversarial review of: {subject}

> This file is populated by the **adversarial reviewer** (see
> `{PROMPT_NAME}`). One entry per change, each with a What and a Why. Leave it
> empty until the review runs.

<!-- entries appended here by the reviewer -->
"""


@dataclass
class ChangeEntry:
    what: str
    why: str

    def to_dict(self) -> dict:
        return {"what": self.what, "why": self.why}


def parse_changelog(text: str) -> list:
    """Parse a reviewer-written changelog into [{what, why}] entries.

    Tolerant of the formatting models actually produce: an entry begins at a
    ``**What:**`` lead and runs until the next ``**What:**`` (or EOF); within it,
    the first ``**Why:**`` lead supplies the rationale. Bold markers, list
    bullets, and leading whitespace are all optional. Entries missing a Why are
    still returned (with an empty why) so the caller can flag them.
    """
    what_re = re.compile(r"^\s*[-*+]?\s*\*{0,2}\s*what\s*\*{0,2}\s*:\s*\*{0,2}\s*(.*)$", re.IGNORECASE)
    why_re = re.compile(r"^\s*[-*+]?\s*\*{0,2}\s*why\s*\*{0,2}\s*:\s*\*{0,2}\s*(.*)$", re.IGNORECASE)

    entries: list = []
    cur_what: Optional[list] = None
    cur_why: Optional[list] = None
    in_why = False

    def flush() -> None:
        nonlocal cur_what, cur_why, in_why
        if cur_what is not None:
            entries.append(
                ChangeEntry(
                    what=" ".join(p.strip() for p in cur_what if p.strip()).strip(),
                    why=" ".join(p.strip() for p in (cur_why or []) if p.strip()).strip(),
                )
            )
        cur_what, cur_why, in_why = None, None, False

    for line in text.splitlines():
        m_what = what_re.match(line)
        if m_what:
            flush()
            cur_what = [m_what.group(1)]
            cur_why = []
            in_why = False
            continue
        if cur_what is None:
            continue
        m_why = why_re.match(line)
        if m_why:
            cur_why = [m_why.group(1)]
            in_why = True
            continue
        # Continuation line for whichever field we are currently in.
        if in_why:
            cur_why.append(line)
        else:
            cur_what.append(line)
    flush()
    return entries


def bump_branch(slug: str, exists: Callable[[str], bool]) -> str:
    """Return ``feat/<slug>`` unless it exists, then ``feat/<slug>-2``, ``-3`` ...

    ``exists`` is injected so the collision logic is testable without git.
    """
    base = f"feat/{slug}"
    if not exists(base):
        return base
    n = 2
    while exists(f"{base}-{n}"):
        n += 1
    return f"{base}-{n}"


def compose_pr_body(subject: str, plan_path: str, changelog_path: str) -> str:
    return f"""## Summary

Implements: {subject}

This PR is being built **in parallel** with an adversarial review of the plan
(`{plan_path}`). Foundational/low-churn pieces land first; design-sensitive work
follows once the review changelog is in.

## Status

- Plan: `{plan_path}`
- Adversarial review: in flight (`{changelog_path}` pending)

## Test plan

- [ ] (transcribe acceptance criteria from the plan here)
"""


# --------------------------------------------------------------------------- #
# Side-effecting helpers (git / gh / code / fs)                                #
# --------------------------------------------------------------------------- #


def _run(cmd: list, *, cwd: Optional[Path] = None, check: bool = True, capture: bool = True):
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        check=check,
        text=True,
        capture_output=capture,
    )


def _git_value(git_args: list, cwd: Optional[Path] = None, default: str = "") -> str:
    """Run a git command and return stripped stdout; return default on any error."""
    try:
        return _run(git_args, cwd=cwd, check=False).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return default


def _repo_root(explicit: Optional[str] = None) -> Path:
    if explicit:
        return Path(explicit).resolve()
    out = _git_value(["git", "rev-parse", "--show-toplevel"])
    return Path(out) if out else Path.cwd()


def _default_base(repo_root: Path, explicit: Optional[str] = None) -> str:
    if explicit:
        return explicit
    ref = _git_value(
        ["git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
        cwd=repo_root,
    )
    return ref.split("/", 1)[-1] if ref else "main"


def _write_if_absent(path: Path, content: str, *, force: bool, created: list, skipped: list) -> None:
    if path.exists() and not force:
        skipped.append(path.name)
        return
    path.write_text(content, encoding="utf-8")
    created.append(path.name)


def _branch_or_worktree_exists(repo_root: Path, name: str) -> bool:
    branch = _run(
        ["git", "show-ref", "--verify", "--quiet", f"refs/heads/{name}"],
        cwd=repo_root,
        check=False,
        capture=True,
    )
    if branch.returncode == 0:
        return True
    wt = _run(["git", "worktree", "list", "--porcelain"], cwd=repo_root, check=False).stdout
    return f"[{name}]" in wt


def _open_in_vscode(paths: list) -> bool:
    """Open the first path fresh, the rest reusing the window. Best-effort."""
    opened = False
    for i, p in enumerate(paths):
        flag = [] if i == 0 else ["-r"]
        try:
            _run(["code", *flag, str(p)], check=False, capture=True)
            opened = True
        except FileNotFoundError:
            return False
    return opened


# --------------------------------------------------------------------------- #
# Subcommands                                                                  #
# --------------------------------------------------------------------------- #


def cmd_init(args: argparse.Namespace) -> int:
    repo_root = _repo_root(args.repo_root)
    base = _default_base(repo_root, args.base)
    has_docs = (repo_root / "docs").is_dir()
    workdir = Path(args.workdir).resolve() if args.workdir else None
    m = resolve_manifest(
        args.subject, repo_root=repo_root, base=base, has_docs=has_docs, workdir=workdir
    )
    wd = Path(m.workdir)
    wd.mkdir(parents=True, exist_ok=True)
    _write_if_absent(
        wd / PLAN_NAME, render_plan_skeleton(m.subject), force=args.force, created=m.created, skipped=m.skipped
    )
    _write_if_absent(
        wd / PROMPT_NAME, render_prompt(), force=args.force, created=m.created, skipped=m.skipped
    )
    _write_if_absent(
        wd / CHANGELOG_NAME,
        render_changelog_stub(m.subject),
        force=args.force,
        created=m.created,
        skipped=m.skipped,
    )
    if args.json:
        print(m.to_json())
    else:
        print(f"workdir: {m.workdir}")
        print(f"slug:    {m.slug}")
        print(f"branch:  {m.branch}  (base {m.base})")
        print(f"created: {', '.join(m.created) or '(none)'}")
        print(f"skipped: {', '.join(m.skipped) or '(none)'}")
    return 0


def cmd_open(args: argparse.Namespace) -> int:
    wd = Path(args.workdir).resolve()
    paths = [wd / PLAN_NAME, wd / PROMPT_NAME, wd / CHANGELOG_NAME]
    missing = [p.name for p in paths if not p.exists()]
    if missing:
        print(f"warning: not found in {wd}: {', '.join(missing)}", file=sys.stderr)
    if not _open_in_vscode([p for p in paths if p.exists()]):
        print("warning: `code` CLI unavailable; open these manually:", file=sys.stderr)
        for p in paths:
            print(f"  {p}", file=sys.stderr)
        return 1
    return 0


def cmd_start_impl(args: argparse.Namespace) -> int:
    repo_root = _repo_root(args.repo_root)
    base = _default_base(repo_root, args.base)
    _run(["git", "fetch", "origin"], cwd=repo_root, check=False)
    branch = bump_branch(args.slug, lambda n: _branch_or_worktree_exists(repo_root, n))
    impl_dir = repo_root / ".worktrees" / args.slug
    suffix = 2
    while impl_dir.exists():
        impl_dir = repo_root / ".worktrees" / f"{args.slug}-{suffix}"
        suffix += 1
    _run(
        ["git", "worktree", "add", str(impl_dir), f"origin/{base}", "-b", branch],
        cwd=repo_root,
    )
    out = {"branch": branch, "base": base, "impl_dir": str(impl_dir)}
    print(json.dumps(out, indent=2) if args.json else f"worktree: {impl_dir}\nbranch:   {branch} (base {base})")
    return 0


def cmd_pr(args: argparse.Namespace) -> int:
    repo_root = _repo_root(args.repo_root)
    base = _default_base(repo_root, args.base)
    impl_dir = repo_root / ".worktrees" / args.slug
    branch = bump_branch(args.slug, lambda n: False)  # caller-provided slug -> feat/<slug>
    if args.branch:
        branch = args.branch
    # Idempotent: reuse an existing PR for this branch.
    existing = _run(
        ["gh", "pr", "list", "--head", branch, "--json", "url,number,state", "--limit", "1"],
        cwd=impl_dir if impl_dir.exists() else repo_root,
        check=False,
    ).stdout.strip()
    url = ""
    try:
        rows = json.loads(existing) if existing else []
    except json.JSONDecodeError:
        rows = []
    _run(["git", "push", "-u", "origin", branch], cwd=impl_dir, check=False)
    if rows:
        url = rows[0].get("url", "")
    else:
        body = compose_pr_body(args.subject, args.plan_path or "", args.changelog_path or "")
        import tempfile

        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as fh:
            fh.write(body)
            body_file = fh.name
        _run(
            [
                "gh", "pr", "create", "--draft", "--base", base, "--head", branch,
                "--title", f"feat: {args.subject}", "--body-file", body_file,
            ],
            cwd=impl_dir,
        )
        url = _run(
            ["gh", "pr", "view", branch, "--json", "url", "--jq", ".url"],
            cwd=impl_dir,
            check=False,
        ).stdout.strip()
    if url and not args.no_open:
        _run(["gh", "pr", "view", url, "--web"], cwd=impl_dir, check=False)
    print(json.dumps({"branch": branch, "url": url}, indent=2) if args.json else f"pr: {url or '(unknown)'}")
    return 0


def cmd_parse_changelog(args: argparse.Namespace) -> int:
    if args.path == "-":
        text = sys.stdin.read()
    else:
        text = Path(args.path).read_text(encoding="utf-8")
    entries = parse_changelog(text)
    if args.json:
        print(json.dumps([e.to_dict() for e in entries], indent=2))
    else:
        if not entries:
            print("(no entries found)")
        for i, e in enumerate(entries, 1):
            print(f"{i}. WHAT: {e.what}")
            print(f"   WHY:  {e.why or '(missing rationale)'}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description="Deterministic mechanics for /pst:adversarial-review.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_init = sub.add_parser("init", help="scaffold artifacts + print manifest")
    p_init.add_argument("subject")
    p_init.add_argument("--base", default=None)
    p_init.add_argument("--workdir", default=None)
    p_init.add_argument("--repo-root", default=None)
    p_init.add_argument("--force", action="store_true", help="overwrite existing artifacts")
    p_init.add_argument("--json", action="store_true")
    p_init.set_defaults(func=cmd_init)

    p_open = sub.add_parser("open", help="open the three artifacts in VS Code")
    p_open.add_argument("--workdir", required=True)
    p_open.set_defaults(func=cmd_open)

    p_si = sub.add_parser("start-impl", help="create an isolated worktree + branch")
    p_si.add_argument("--slug", required=True)
    p_si.add_argument("--base", default=None)
    p_si.add_argument("--repo-root", default=None)
    p_si.add_argument("--json", action="store_true")
    p_si.set_defaults(func=cmd_start_impl)

    p_pr = sub.add_parser("pr", help="push + open a draft PR (idempotent)")
    p_pr.add_argument("--slug", required=True)
    p_pr.add_argument("--subject", required=True)
    p_pr.add_argument("--workdir", required=True)
    p_pr.add_argument("--plan-path", default=None)
    p_pr.add_argument("--changelog-path", default=None)
    p_pr.add_argument("--branch", default=None)
    p_pr.add_argument("--base", default=None)
    p_pr.add_argument("--repo-root", default=None)
    p_pr.add_argument("--no-open", action="store_true")
    p_pr.add_argument("--json", action="store_true")
    p_pr.set_defaults(func=cmd_pr)

    p_cl = sub.add_parser("parse-changelog", help="parse a reviewer changelog into entries")
    p_cl.add_argument("path", help="path to CHANGELOG.md, or - for stdin")
    p_cl.add_argument("--json", action="store_true")
    p_cl.set_defaults(func=cmd_parse_changelog)

    return ap


def main(argv: Optional[list] = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
