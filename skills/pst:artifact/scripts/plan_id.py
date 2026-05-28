#!/usr/bin/env python3
"""Generate a fresh, collision-checked short id for a new pst:artifact artifact.

The id is the studio MDX filename and lives forever in the URL (/p/<id>/<slug>),
so it must be stable and unique. Uses an unambiguous lowercase base32-ish
alphabet (no 0/o/1/l/i) at length 6 (~10^9 space) — plenty, and easy to read.

  plan_id.py --plans-dir studio/src/content/plans
  plan_id.py --plans-dir studio/src/content/plans --slug "Q3 Platform Migration"
      -> "<id>\\t<slug>"
"""

from __future__ import annotations

import argparse
import re
import secrets
from pathlib import Path

ALPHABET = "23456789abcdefghijkmnpqrstuvwxyz"
DEFAULT_LEN = 6

__all__ = ["existing_ids", "gen_id", "slugify"]


def existing_ids(plans_dir: Path) -> set[str]:
    """Ids already in use (MDX/MD filenames, sans extension)."""
    if not plans_dir.is_dir():
        return set()
    return {p.stem for p in plans_dir.iterdir() if p.suffix in {".md", ".mdx"}}


def gen_id(length: int, taken: set[str]) -> str:
    """A random id of `length` not present in `taken`."""
    for _ in range(10_000):
        candidate = "".join(secrets.choice(ALPHABET) for _ in range(length))
        if candidate not in taken:
            return candidate
    raise SystemExit("plan_id: exhausted attempts finding a free id")


def slugify(text: str) -> str:
    """A cosmetic, human-readable URL slug (never used for routing)."""
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    s = re.sub(r"-{2,}", "-", s)
    return s[:60] or "artifact"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plans-dir", required=True, type=Path)
    parser.add_argument("--length", type=int, default=DEFAULT_LEN)
    parser.add_argument("--slug", help="title to slugify; prints '<id>\\t<slug>'")
    args = parser.parse_args()

    new_id = gen_id(args.length, existing_ids(args.plans_dir))
    if args.slug:
        print(f"{new_id}\t{slugify(args.slug)}")
    else:
        print(new_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
