#!/usr/bin/env python3
"""Catalog & overlay management CLI for the pst:secrets drawer.

Commands:
  secret_config.py show                  # print catalog path + summary
  secret_config.py refresh               # discover op accounts/vaults, merge, save
  secret_config.py doctor                # validate CLI/auth/catalog/overlays/registry
  secret_config.py set-default PROFILE   # set the global default drawer profile
  secret_config.py profile NAME --backend op --account A --vault V   # define a profile
  secret_config.py alias --account ID --as NAME [--vault VID --vault-as NAME]
                         [--label "family shared"]                   # human metadata
  secret_config.py project [--path DIR] (--profile P | --account A --vault V [--backend op])

Guided first-run setup (asking which vaults to alias, picking a default) is
driven by the calling agent via its question UI; this CLI provides the
primitives those steps call.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import config as C
from registry import all_drawers


def _ensure_catalog() -> C.Catalog:
    catalog = C.load_catalog()
    if catalog is None:
        catalog = C.Catalog(trusted_overlay_roots=["~/workspaces"])
    return catalog


def cmd_show(args: argparse.Namespace) -> int:
    catalog = C.load_catalog()
    if catalog is None:
        print(f"No catalog at {C.CONFIG_PATH}. Run `/pst:secrets config` (refresh).")
        return 0
    print(f"catalog: {C.CONFIG_PATH}")
    print(f"default_profile: {catalog.default_profile or '(none)'}")
    print(C.catalog_summary(catalog))
    if catalog.profiles:
        print("profiles:")
        for p in catalog.profiles.values():
            tgt = f"{p.account}/{p.vault}" if p.backend == "op" else p.account
            print(f"  {p.name}: {p.backend} {tgt}")
    print(f"trusted_overlay_roots: {', '.join(catalog.trusted_overlay_roots) or '(none)'}")
    return 0


def cmd_refresh(args: argparse.Namespace) -> int:
    catalog = _ensure_catalog()
    try:
        discovered = C.discover_op()
    except C.ConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    C.refresh_catalog(catalog, discovered, _now())
    try:
        C.save_catalog(catalog)
    except C.ConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    print(f"Discovered {len(discovered)} account(s). Catalog saved to {C.CONFIG_PATH}.")
    print(C.catalog_summary(catalog))
    return 0


def cmd_doctor(args: argparse.Namespace) -> int:
    problems = 0
    if not C.op_available():
        print("✗ `op` CLI not found on PATH. Install: brew install 1password-cli")
        problems += 1
    else:
        print("✓ op CLI present")
    catalog = C.load_catalog()
    if catalog is None:
        print(f"✗ no catalog at {C.CONFIG_PATH}; run `/pst:secrets config` (refresh)")
        return 1
    print("✓ catalog present")
    try:
        C._validate_unique_aliases(catalog)
        print("✓ aliases unique")
    except C.ConfigError as exc:
        print(f"✗ {exc}")
        problems += 1
    for acct in catalog.op_accounts.values():
        if acct.missing_since:
            print(f"⚠ account '{acct.handle}' missing since {acct.missing_since}")
            continue
        # Probe with a real read; `op whoami` falsely reports "not signed in"
        # under desktop-app integration even when commands are authorized.
        res = C._op("vault", "list", "--account", acct.selector or acct.id, "--format=json")
        if res.returncode == 0:
            print(f"✓ reachable: {acct.handle}")
        else:
            print(f"⚠ not reachable: {acct.handle} (unlock the app / run op signin)")
    if catalog.default_profile and catalog.default_profile not in catalog.profiles:
        print(f"✗ default_profile '{catalog.default_profile}' is not a defined profile")
        problems += 1
    # overlay under cwd
    overlay = C.find_overlay(Path.cwd(), catalog)
    if overlay:
        print(f"✓ trusted overlay: {overlay[0]}")
    # registry drawers referencing unknown op accounts
    known_ids = set(catalog.op_accounts)
    for did, d in all_drawers().items():
        if d.get("backend") == "op" and d.get("account_id") not in known_ids:
            print(f"⚠ registry drawer {did} references an account not in the catalog")
    print("doctor: OK" if problems == 0 else f"doctor: {problems} problem(s)")
    return 0 if problems == 0 else 1


def cmd_set_default(args: argparse.Namespace) -> int:
    catalog = _ensure_catalog()
    if args.profile not in catalog.profiles:
        print(f"Unknown profile '{args.profile}'. Define it first with `profile`.",
              file=sys.stderr)
        return 2
    catalog.default_profile = args.profile
    C.save_catalog(catalog)
    print(f"default_profile = {args.profile}")
    return 0


def cmd_profile(args: argparse.Namespace) -> int:
    catalog = _ensure_catalog()
    catalog.profiles[args.name] = C.Profile(
        name=args.name, backend=args.backend, account=args.account or "",
        vault=args.vault or "")
    C.save_catalog(catalog)
    print(f"profile '{args.name}' = {args.backend} {args.account or ''}/{args.vault or ''}")
    return 0


def cmd_alias(args: argparse.Namespace) -> int:
    catalog = _ensure_catalog()
    acct = catalog.op_accounts.get(args.account) or catalog.op_account_by_handle(args.account)
    if acct is None:
        print(f"Unknown account '{args.account}'. Run refresh first.", file=sys.stderr)
        return 2
    if args.set_as:
        acct.alias = args.set_as
    if args.vault:
        vault = acct.vaults.get(args.vault)
        if vault is None:
            print(f"Unknown vault id '{args.vault}' in account '{acct.handle}'.",
                  file=sys.stderr)
            return 2
        if args.vault_as:
            vault.alias = args.vault_as
        if args.label:
            if args.label not in vault.semantic_labels:
                vault.semantic_labels.append(args.label)
    C.save_catalog(catalog)
    print("alias updated")
    return 0


def cmd_project(args: argparse.Namespace) -> int:
    catalog = C.load_catalog()
    if catalog is None:
        print("No catalog yet; run refresh first.", file=sys.stderr)
        return 2
    target_dir = Path(os.path.expanduser(args.path)).resolve() if args.path else Path.cwd()
    roots = catalog.trusted_roots_resolved()
    if not any(_is_under(target_dir, r) for r in roots):
        print(f"Refusing to write an overlay at {target_dir}: not under a "
              f"trusted_overlay_root ({', '.join(catalog.trusted_overlay_roots)}).",
              file=sys.stderr)
        return 2
    overlay: dict = {}
    if args.profile:
        if args.profile not in catalog.profiles:
            print(f"Unknown profile '{args.profile}'.", file=sys.stderr)
            return 2
        overlay["profile"] = args.profile
    else:
        if not (args.account and args.vault):
            print("Pass --profile, or --account and --vault.", file=sys.stderr)
            return 2
        overlay = {"backend": args.backend, "account": args.account, "vault": args.vault}
    path = target_dir / C.OVERLAY_FILENAME
    import json
    path.write_text(json.dumps(overlay, indent=2) + "\n")
    print(f"Wrote overlay {path}: {overlay}")
    print("Reminder: keep this gitignored unless you intend to share routing metadata.")
    return 0


def _is_under(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _now() -> str:
    import datetime
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def main() -> int:
    ap = argparse.ArgumentParser(description="pst:secrets catalog & overlay management.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("show")
    sub.add_parser("refresh")
    sub.add_parser("doctor")
    d = sub.add_parser("set-default"); d.add_argument("profile")
    p = sub.add_parser("profile")
    p.add_argument("name")
    p.add_argument("--backend", choices=("op", "aws-ssm"), default="op")
    p.add_argument("--account")
    p.add_argument("--vault")
    a = sub.add_parser("alias")
    a.add_argument("--account", required=True)
    a.add_argument("--as", dest="set_as")
    a.add_argument("--vault")
    a.add_argument("--vault-as", dest="vault_as")
    a.add_argument("--label")
    pr = sub.add_parser("project")
    pr.add_argument("--path")
    pr.add_argument("--profile")
    pr.add_argument("--backend", choices=("op", "aws-ssm"), default="op")
    pr.add_argument("--account")
    pr.add_argument("--vault")
    args = ap.parse_args()

    return {
        "show": cmd_show, "refresh": cmd_refresh, "doctor": cmd_doctor,
        "set-default": cmd_set_default, "profile": cmd_profile,
        "alias": cmd_alias, "project": cmd_project,
    }[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
