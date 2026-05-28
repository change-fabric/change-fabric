#!/usr/bin/env python3
"""Shared local pointer registry for the pst:secrets credential drawer.

The registry never stores secret *values* -- only pointers (names -> where the
value lives in the chosen backend). It is the one piece of on-disk state shared
by every backend (1Password, AWS SSM), which is why `list` works without
unlocking anything.

v2 layout -- keyed by stable *drawer IDs* rather than mutable display names so
that vault/account renames and cross-account name collisions can never corrupt
or alias a pointer:

  {"version": 2,
   "drawers": {
     "op:acct:<account-id>:vault:<vault-id>": {
        "backend": "op", "account_id", "account", "vault_id", "vault",
        "secrets": {"NAME": {"item_id", "field", "label", "updated"}}},
     "aws:account:<account-id>:region:<region>:prefix:<prefix>": {
        "backend": "aws-ssm", "account_id", "region", "kms_key", "prefix",
        "secrets": {"NAME": {"ssm_path", "label", "updated"}}}}}

`_normalize` migrates the two older shapes (a flat v0 `{"secrets": {...}}` and a
v1 `{"accounts": {...}}`) forward without ever dropping a pointer.
"""
from __future__ import annotations

import datetime as _dt
import json
import os
from pathlib import Path

REGISTRY_PATH = Path(os.path.expanduser("~/.config/pst-secrets/registry.json"))
REGISTRY_VERSION = 2

__all__ = [
    "REGISTRY_PATH",
    "REGISTRY_VERSION",
    "now_iso",
    "op_drawer_id",
    "aws_drawer_id",
    "load_registry",
    "save_registry",
    "ensure_drawer",
    "get_drawer",
    "put_pointer",
    "get_pointer",
    "delete_pointer",
    "all_drawers",
]


def now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds")


def op_drawer_id(account_id: str, vault_id: str) -> str:
    return f"op:acct:{account_id}:vault:{vault_id}"


def aws_drawer_id(account_id: str, region: str, prefix: str) -> str:
    return f"aws:account:{account_id}:region:{region}:prefix:{prefix}"


# ---------------------------------------------------------------- migration

def _migrate_v1_accounts(reg: dict) -> dict:
    """v1 `{"accounts": {acct: {region, kms_key, secrets}}}` -> v2 aws drawers."""
    drawers: dict = {}
    for account_id, acct in reg.get("accounts", {}).items():
        region = acct.get("region", "") or "us-east-1"
        secrets = acct.get("secrets", {}) or {}
        # v1 had no per-account prefix; recover it from a stored ssm_path when
        # possible, else fall back to the historical default.
        prefix = "/pst-secrets"
        for meta in secrets.values():
            ssm_path = meta.get("ssm_path")
            if ssm_path and "/" in ssm_path.rstrip("/"):
                prefix = ssm_path.rsplit("/", 1)[0] or prefix
                break
        drawer_id = aws_drawer_id(account_id, region, prefix)
        drawers[drawer_id] = {
            "backend": "aws-ssm",
            "account_id": account_id,
            "region": region,
            "kms_key": acct.get("kms_key", ""),
            "prefix": prefix,
            "secrets": secrets,
        }
    return {"version": REGISTRY_VERSION, "drawers": drawers}


def _migrate_v0_flat(reg: dict) -> dict:
    """Oldest flat `{"account", "region", "kms_key", "secrets"}` -> v2."""
    account_id = reg.get("account", "unknown")
    region = reg.get("region", "") or "us-east-1"
    secrets = reg.get("secrets", {}) or {}
    drawers: dict = {}
    if secrets:
        prefix = "/pst-secrets"
        for meta in secrets.values():
            ssm_path = meta.get("ssm_path")
            if ssm_path and "/" in ssm_path.rstrip("/"):
                prefix = ssm_path.rsplit("/", 1)[0] or prefix
                break
        drawers[aws_drawer_id(account_id, region, prefix)] = {
            "backend": "aws-ssm",
            "account_id": account_id,
            "region": region,
            "kms_key": reg.get("kms_key", ""),
            "prefix": prefix,
            "secrets": secrets,
        }
    return {"version": REGISTRY_VERSION, "drawers": drawers}


def _normalize(reg: dict) -> dict:
    if reg.get("version") == REGISTRY_VERSION and "drawers" in reg:
        reg.setdefault("drawers", {})
        return reg
    if "drawers" in reg:  # future-proof: drawers present but version mismatch
        reg["version"] = REGISTRY_VERSION
        return reg
    if "accounts" in reg:
        return _migrate_v1_accounts(reg)
    return _migrate_v0_flat(reg)


# ---------------------------------------------------------------- load / save

def load_registry() -> dict:
    if REGISTRY_PATH.exists():
        return _normalize(json.loads(REGISTRY_PATH.read_text()))
    return {"version": REGISTRY_VERSION, "drawers": {}}


def save_registry(reg: dict) -> None:
    REGISTRY_PATH.parent.mkdir(parents=True, exist_ok=True)
    REGISTRY_PATH.write_text(json.dumps(reg, indent=2) + "\n")
    os.chmod(REGISTRY_PATH, 0o600)


# ---------------------------------------------------------------- drawer ops

def get_drawer(reg: dict, drawer_id: str) -> dict | None:
    return reg.get("drawers", {}).get(drawer_id)


def ensure_drawer(reg: dict, drawer_id: str, **fields: object) -> dict:
    drawers = reg.setdefault("drawers", {})
    drawer = drawers.setdefault(drawer_id, {"secrets": {}})
    drawer.update({k: v for k, v in fields.items() if v is not None})
    drawer.setdefault("secrets", {})
    return drawer


def put_pointer(drawer_id: str, name: str, pointer: dict, **drawer_fields: object) -> None:
    reg = load_registry()
    drawer = ensure_drawer(reg, drawer_id, **drawer_fields)
    entry = dict(pointer)
    entry.setdefault("updated", now_iso())
    drawer["secrets"][name] = entry
    save_registry(reg)


def get_pointer(drawer_id: str, name: str) -> dict | None:
    drawer = get_drawer(load_registry(), drawer_id)
    if not drawer:
        return None
    return drawer.get("secrets", {}).get(name)


def delete_pointer(drawer_id: str, name: str) -> bool:
    reg = load_registry()
    drawer = get_drawer(reg, drawer_id)
    if not drawer:
        return False
    secrets = drawer.get("secrets", {})
    if name in secrets:
        del secrets[name]
        save_registry(reg)
        return True
    return False


def all_drawers() -> dict:
    """Pointer metadata grouped by drawer -- never values. Needs no unlock."""
    return load_registry().get("drawers", {})
