#!/usr/bin/env python3
"""Fetch / list / delete pst:secrets values across backends (1Password, AWS SSM).

The read half of the secret loop. `get`/`export`/`rm` locate the secret in the
local pointer registry, build the right backend adapter, and operate on it; a
backend that needs a live session (AWS) or an unlocked app (1Password) fails
with an actionable message. `list` reads only the local registry -- no unlock.

Usage:
  secret_fetch.py get    NAME                # print one value to stdout (capture in a var)
  secret_fetch.py export NAME [NAME ...]     # emit eval-able `export NAME="value"` lines
  secret_fetch.py list                       # known names + pointers grouped by drawer
  secret_fetch.py rm     NAME                # delete a secret (backend item + local pointer)

Scope with --profile/--account/--vault/--aws when the same NAME lives in more
than one drawer.

Security: `get` prints the raw value to stdout by design (the consumption
interface -- capture it in a subshell). `list` shows only names/pointers/times.
"""
from __future__ import annotations

import argparse
import sys

from backend import backend_from_drawer
from registry import all_drawers


def _shell_quote(v: str) -> str:
    return "'" + v.replace("'", "'\"'\"'") + "'"


class LocateError(RuntimeError):
    pass


def _matching_drawer_ids(name: str) -> list[str]:
    return [did for did, d in all_drawers().items()
            if name in d.get("secrets", {})]


def _scope_filter(args: argparse.Namespace) -> "callable | None":
    """Optional predicate to narrow drawers by flag, for disambiguation."""
    def pred(drawer: dict) -> bool:
        if args.aws and drawer.get("backend") != "aws-ssm":
            return False
        if args.account:
            handles = {drawer.get("account"), drawer.get("account_id")}
            if args.account not in handles:
                return False
        if args.vault:
            handles = {drawer.get("vault"), drawer.get("vault_id")}
            if args.vault not in handles:
                return False
        return True
    if args.aws or args.account or args.vault:
        return pred
    return None


def _locate(name: str, args: argparse.Namespace):
    drawers = all_drawers()
    ids = _matching_drawer_ids(name)
    pred = _scope_filter(args)
    if pred:
        ids = [did for did in ids if pred(drawers[did])]
    if not ids:
        raise LocateError(f"No secret '{name}' registered. Capture one via "
                          f"/pst:secrets set \"<description>\".")
    if len(ids) > 1:
        where = ", ".join(ids)
        raise LocateError(f"'{name}' exists in multiple drawers: {where}. "
                          f"Disambiguate with --account/--vault/--aws.")
    drawer_id = ids[0]
    return backend_from_drawer(drawers[drawer_id])


def _print_list() -> int:
    drawers = all_drawers()
    if not drawers or not any(d.get("secrets") for d in drawers.values()):
        print("No secrets registered. Capture one via /pst:secrets set \"<description>\".")
        return 0
    for drawer_id, d in sorted(drawers.items()):
        secrets = d.get("secrets", {})
        if not secrets:
            continue
        if d.get("backend") == "op":
            header = f"op  ·  {d.get('account','?')}  ·  vault {d.get('vault') or d.get('vault_id','?')}"
        else:
            header = (f"aws  ·  account {d.get('account_id','?')}  ·  "
                      f"{d.get('region','?')}  ·  {d.get('prefix','?')}")
        print(f"\n{header}")
        width = max(len(n) for n in secrets)
        for sname, m in sorted(secrets.items()):
            ptr = m.get("ssm_path") or (f"item {m.get('item_id','?')}/{m.get('field','?')}")
            print(f"  {sname:<{width}}  {ptr}  ({m.get('updated','?')})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Fetch pst:secrets values across backends.")
    ap.add_argument("--aws", action="store_true", help="scope to the AWS backend")
    ap.add_argument("--account", help="scope to an op account handle / aws account")
    ap.add_argument("--vault", help="scope to an op vault")
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("get", help="print one value to stdout")
    g.add_argument("name")
    e = sub.add_parser("export", help="emit `export NAME=value` lines")
    e.add_argument("names", nargs="+")
    sub.add_parser("list", help="list known secret names + pointers (no values)")
    r = sub.add_parser("rm", help="delete a secret (backend item + local pointer)")
    r.add_argument("name")
    args = ap.parse_args()

    try:
        if args.cmd == "list":
            return _print_list()
        if args.cmd == "get":
            backend = _locate(args.name, args)
            sys.stdout.write(backend.get(args.name))
            return 0
        if args.cmd == "export":
            for name in args.names:
                backend = _locate(name, args)
                sys.stdout.write(f"export {name}={_shell_quote(backend.get(name))}\n")
            return 0
        if args.cmd == "rm":
            backend = _locate(args.name, args)
            backend.delete(args.name)
            print(f"Deleted '{args.name}' (backend item + local pointer).", file=sys.stderr)
            return 0
    except LocateError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except Exception as exc:  # backend OpError / SecretError carry actionable text
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 1


if __name__ == "__main__":
    sys.exit(main())
