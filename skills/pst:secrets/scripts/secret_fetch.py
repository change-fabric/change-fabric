#!/usr/bin/env python3
"""Fetch pst:secrets values from AWS SSM (KMS-decrypted) on demand.

The read half of the AWS-backed secret loop. Requires a live AWS session - in
practice an MFA-gated one from /aws-mfa. No session ⇒ clear failure telling you
to re-authenticate; secrets are never written back to disk in plaintext.

Usage:
  secret_fetch.py get   NAME                 # print one decrypted value to stdout
  secret_fetch.py export NAME [NAME ...]     # emit `export NAME="value"` lines (eval-able)
  secret_fetch.py list                       # list known secret names + pointers (no values)
  secret_fetch.py rm    NAME                 # delete a secret (SSM + local pointer)

Config via env (see aws_secrets.py) or flags: --profile --region --kms-key --prefix.
Configure via env (see aws_secrets.py) or the --profile/--region/--kms-key/--prefix flags.

Security: `get` prints the raw value to stdout by design (that's the consumption
interface - capture it in a subshell). `list` shows only names/paths/timestamps.
"""
from __future__ import annotations

import argparse
import sys

from aws_secrets import Config, SecretError, delete_secret, get_secret, list_accounts


def _cfg(args: argparse.Namespace) -> Config:
    return Config.from_env(
        profile=args.profile, region=args.region, kms_key=args.kms_key, prefix=args.prefix
    )


def _shell_quote(v: str) -> str:
    return "'" + v.replace("'", "'\"'\"'") + "'"


def main() -> int:
    ap = argparse.ArgumentParser(description="Fetch pst:secrets values from AWS SSM (KMS-decrypted).")
    ap.add_argument("--profile")
    ap.add_argument("--region")
    ap.add_argument("--kms-key", dest="kms_key")
    ap.add_argument("--prefix")
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("get", help="print one decrypted value to stdout")
    g.add_argument("name")
    e = sub.add_parser("export", help="emit `export NAME=value` lines")
    e.add_argument("names", nargs="+")
    sub.add_parser("list", help="list known secret names + pointers (no values)")
    r = sub.add_parser("rm", help="delete a secret (SSM + local pointer)")
    r.add_argument("name")
    args = ap.parse_args()
    cfg = _cfg(args)

    try:
        if args.cmd == "get":
            sys.stdout.write(get_secret(cfg, args.name))
            return 0
        if args.cmd == "export":
            for name in args.names:
                val = get_secret(cfg, name)
                sys.stdout.write(f"export {name}={_shell_quote(val)}\n")
            return 0
        if args.cmd == "list":
            accounts = list_accounts()
            if not accounts or not any(a.get("secrets") for a in accounts.values()):
                print("No secrets registered. Capture one via /pst:secrets set \"<description>\".")
                return 0
            for account, meta in sorted(accounts.items()):
                secrets = meta.get("secrets", {})
                if not secrets:
                    continue
                print(f"\naccount {account}  ·  {meta.get('region','?')}  ·  {meta.get('kms_key','?')}")
                width = max(len(n) for n in secrets)
                for name, m in sorted(secrets.items()):
                    print(f"  {name:<{width}}  {m.get('ssm_path','?')}  ({m.get('updated','?')})")
            return 0
        if args.cmd == "rm":
            delete_secret(cfg, args.name)
            print(f"Deleted '{args.name}' (SSM parameter + local pointer).", file=sys.stderr)
            return 0
    except SecretError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 1


if __name__ == "__main__":
    sys.exit(main())
