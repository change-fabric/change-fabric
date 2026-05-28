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

When a session cache is live (see `session_cache.py` / `/pst:secrets session
start`), `get`/`export` read from it first -- no backend unlock -- and warm any
backend miss back into it. Pass `--fresh` (alias `--no-session`) to force a
backend read.

Security: `get` prints the raw value to stdout by design (the consumption
interface -- capture it in a subshell). `list` shows only names/pointers/times.
"""
from __future__ import annotations

import argparse
import sys

import session_cache
from backend import backend_from_drawer
from registry import all_drawers


def _shell_quote(v: str) -> str:
    return "'" + v.replace("'", "'\"'\"'") + "'"


class LocateError(RuntimeError):
    pass


def _matching_drawer_ids(name: str) -> list[str]:
    return [did for did, d in all_drawers().items()
            if name in d.get("secrets", {})]


def _scope_filter(aws: bool, account: "str | None", vault: "str | None") -> "callable | None":
    """Optional predicate to narrow drawers by flag, for disambiguation."""
    def pred(drawer: dict) -> bool:
        if aws and drawer.get("backend") != "aws-ssm":
            return False
        if account:
            handles = {drawer.get("account"), drawer.get("account_id")}
            if account not in handles:
                return False
        if vault:
            handles = {drawer.get("vault"), drawer.get("vault_id")}
            if vault not in handles:
                return False
        return True
    if aws or account or vault:
        return pred
    return None


def locate_backend(name: str, *, aws: bool = False,
                   account: "str | None" = None, vault: "str | None" = None):
    """Resolve the single backend holding ``name``, or raise LocateError.

    Shared by the read path and `session start`; scope flags disambiguate a
    NAME that lives in more than one drawer.
    """
    drawers = all_drawers()
    ids = _matching_drawer_ids(name)
    pred = _scope_filter(aws, account, vault)
    if pred:
        ids = [did for did in ids if pred(drawers[did])]
    if not ids:
        raise LocateError(f"No secret '{name}' registered. Capture one via "
                          f"/pst:secrets set \"<description>\".")
    if len(ids) > 1:
        where = ", ".join(ids)
        raise LocateError(f"'{name}' exists in multiple drawers: {where}. "
                          f"Disambiguate with --account/--vault/--aws.")
    return backend_from_drawer(drawers[ids[0]])


def _locate(name: str, args: argparse.Namespace):
    return locate_backend(name, aws=args.aws, account=args.account, vault=args.vault)


def _read_value(name: str, args: argparse.Namespace) -> str:
    """Read one value, preferring a live session cache unless --fresh.

    On a cache miss during a live session the freshly-read backend value is
    warmed into the cache, so the next access stays unlock-free too.
    """
    if not args.fresh:
        cached = session_cache.lookup(name)
        if cached is not None:
            return cached
    backend = _locate(name, args)
    value = backend.get(name)
    if not args.fresh:
        session_cache.warm(name, value, getattr(backend, "drawer_id", None))
    return value


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


def _add_fresh(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--fresh", "--no-session", dest="fresh", action="store_true",
                        help="bypass the session cache and read from the backend")


def main(argv: "list[str] | None" = None) -> int:
    ap = argparse.ArgumentParser(description="Fetch pst:secrets values across backends.")
    ap.add_argument("--aws", action="store_true", help="scope to the AWS backend")
    ap.add_argument("--account", help="scope to an op account handle / aws account")
    ap.add_argument("--vault", help="scope to an op vault")
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("get", help="print one value to stdout")
    g.add_argument("name")
    _add_fresh(g)
    e = sub.add_parser("export", help="emit `export NAME=value` lines")
    e.add_argument("names", nargs="+")
    _add_fresh(e)
    sub.add_parser("list", help="list known secret names + pointers (no values)")
    r = sub.add_parser("rm", help="delete a secret (backend item + local pointer)")
    r.add_argument("name")
    args = ap.parse_args(argv)

    try:
        if args.cmd == "list":
            return _print_list()
        if args.cmd == "get":
            sys.stdout.write(_read_value(args.name, args))
            return 0
        if args.cmd == "export":
            for name in args.names:
                sys.stdout.write(f"export {name}={_shell_quote(_read_value(name, args))}\n")
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
