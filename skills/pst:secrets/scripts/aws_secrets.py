#!/usr/bin/env python3
"""AWS-backed secret storage for the pst:secrets credential drawer.

Secrets are stored as KMS-encrypted SSM Parameter Store *SecureString* values.
The plaintext never lands on disk - only a local *pointer registry* mapping each
logical name to its SSM path is kept locally. Decryption requires a live AWS
session (in practice, an MFA-gated session minted by /aws-mfa); an expired
session simply makes retrieval fail with an actionable message.

This module is intentionally generic (no account/region baked in). Callers
configure it via env vars or explicit kwargs:

  PST_SECRETS_PROFILE   AWS CLI profile to use            (default: AWS default chain)
  PST_SECRETS_REGION    AWS region                        (default: us-east-1)
  PST_SECRETS_KMS_KEY   KMS key id/alias for SecureString (default: alias/pst-secrets)
  PST_SECRETS_PREFIX    SSM parameter name prefix         (default: /pst-secrets)

Environment-specific values (Patrick's personal account, profile pstaylor-mfa)
live in the pst:secrets SKILL.md, not here -- so this stays portable/OSS-able.

It shells out to the `aws` CLI rather than taking a boto3 dependency.
"""
from __future__ import annotations

import datetime as _dt
import json
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path

REGISTRY_PATH = Path(os.path.expanduser("~/.config/pst-secrets/registry.json"))
REGISTRY_VERSION = 1

__all__ = [
    "Config",
    "SecretError",
    "ensure_session",
    "put_secret",
    "get_secret",
    "delete_secret",
    "list_accounts",
    "load_registry",
]


class SecretError(RuntimeError):
    """Raised for any store/fetch failure with a human-actionable message."""


@dataclass(frozen=True)
class Config:
    profile: str | None
    region: str
    kms_key: str
    prefix: str

    @classmethod
    def from_env(cls, **overrides: str | None) -> "Config":
        def pick(key: str, env: str, default: str | None) -> str | None:
            val = overrides.get(key)
            if val:
                return val
            return os.environ.get(env, default)

        return cls(
            profile=pick("profile", "PST_SECRETS_PROFILE", None),
            region=pick("region", "PST_SECRETS_REGION", "us-east-1") or "us-east-1",
            kms_key=pick("kms_key", "PST_SECRETS_KMS_KEY", "alias/pst-secrets")
            or "alias/pst-secrets",
            prefix=pick("prefix", "PST_SECRETS_PREFIX", "/pst-secrets") or "/pst-secrets",
        )

    def ssm_path(self, name: str) -> str:
        return f"{self.prefix.rstrip('/')}/{name}"


def _aws(cfg: Config, *args: str, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    """Run an aws CLI command for this config. Never logs secret material."""
    cmd = ["aws"]
    if cfg.profile:
        cmd += ["--profile", cfg.profile]
    cmd += ["--region", cfg.region, *args]
    return subprocess.run(
        cmd, input=input_text, capture_output=True, text=True, check=False
    )


def _account_of(arn: str) -> str:
    parts = arn.split(":")
    return parts[4] if len(parts) > 4 and parts[4] else "unknown"


def ensure_session(cfg: Config) -> str:
    """Verify a usable AWS session; return the caller ARN. Raise with guidance if not."""
    res = _aws(cfg, "sts", "get-caller-identity", "--output", "json")
    if res.returncode != 0:
        hint = (
            "No active AWS session for "
            f"{'profile ' + cfg.profile if cfg.profile else 'the default profile'}. "
            "Run  /aws-mfa personal <otp>  to mint a 12h MFA session, then retry."
        )
        raise SecretError(hint + "\n" + res.stderr.strip())
    return json.loads(res.stdout).get("Arn", "?")


# ---------------------------------------------------------------- registry
#
# Namespaced by AWS account so the drawer scales to multiple accounts (personal
# + client profiles) without name collisions:
#
#   {"version": 1,
#    "accounts": {
#      "569032832755": {"region": "...", "kms_key": "...",
#                       "secrets": {"NAME": {"ssm_path", "label", "updated"}}}}}
#
# `_normalize` tolerates an older flat `{"secrets": {...}}` shape by folding it
# under its account, so a hand-edited or legacy registry still loads cleanly.

def _normalize(reg: dict) -> dict:
    if "accounts" in reg:  # already namespaced
        reg["version"] = REGISTRY_VERSION
        return reg
    # flat → namespaced
    account = reg.get("account", "unknown")
    migrated: dict = {"version": REGISTRY_VERSION, "backend": "aws-ssm", "accounts": {}}
    if reg.get("secrets"):
        migrated["accounts"][account] = {
            "region": reg.get("region", ""),
            "kms_key": reg.get("kms_key", ""),
            "secrets": reg["secrets"],
        }
    return migrated


def load_registry() -> dict:
    if REGISTRY_PATH.exists():
        return _normalize(json.loads(REGISTRY_PATH.read_text()))
    return {"version": REGISTRY_VERSION, "backend": "aws-ssm", "accounts": {}}


def save_registry(reg: dict) -> None:
    REGISTRY_PATH.parent.mkdir(parents=True, exist_ok=True)
    REGISTRY_PATH.write_text(json.dumps(reg, indent=2) + "\n")
    os.chmod(REGISTRY_PATH, 0o600)


def _account_entry(reg: dict, account: str, cfg: Config) -> dict:
    acct = reg.setdefault("accounts", {}).setdefault(
        account, {"region": cfg.region, "kms_key": cfg.kms_key, "secrets": {}}
    )
    acct["region"], acct["kms_key"] = cfg.region, cfg.kms_key  # keep current
    acct.setdefault("secrets", {})
    return acct


def _registered_path(reg: dict, account: str, name: str, cfg: Config) -> str:
    return (
        reg.get("accounts", {}).get(account, {}).get("secrets", {}).get(name, {}).get("ssm_path")
        or cfg.ssm_path(name)
    )


# ---------------------------------------------------------------- store / fetch

def put_secret(cfg: Config, name: str, value: str, label: str | None = None) -> None:
    """Encrypt+store one secret as a SecureString and record a local pointer."""
    account = _account_of(ensure_session(cfg))
    res = _aws(
        cfg, "ssm", "put-parameter",
        "--name", cfg.ssm_path(name),
        "--type", "SecureString",
        "--key-id", cfg.kms_key,
        "--overwrite",
        "--value", value,
        "--output", "json",
    )
    if res.returncode != 0:
        raise SecretError(f"Failed to store '{name}' in SSM:\n{res.stderr.strip()}")
    reg = load_registry()
    _account_entry(reg, account, cfg)["secrets"][name] = {
        "ssm_path": cfg.ssm_path(name),
        "label": label or name,
        "updated": _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"),
    }
    save_registry(reg)


def get_secret(cfg: Config, name: str) -> str:
    """Fetch+decrypt one secret from the authenticated account. Returns plaintext."""
    account = _account_of(ensure_session(cfg))
    path = _registered_path(load_registry(), account, name, cfg)
    res = _aws(
        cfg, "ssm", "get-parameter",
        "--name", path, "--with-decryption",
        "--query", "Parameter.Value", "--output", "text",
    )
    if res.returncode != 0:
        raise SecretError(f"Failed to fetch '{name}' from SSM:\n{res.stderr.strip()}")
    return res.stdout.rstrip("\n")


def delete_secret(cfg: Config, name: str) -> None:
    account = _account_of(ensure_session(cfg))
    reg = load_registry()
    path = _registered_path(reg, account, name, cfg)
    res = _aws(cfg, "ssm", "delete-parameter", "--name", path)
    if res.returncode != 0 and "ParameterNotFound" not in res.stderr:
        raise SecretError(f"Failed to delete '{name}' from SSM:\n{res.stderr.strip()}")
    secrets = reg.get("accounts", {}).get(account, {}).get("secrets", {})
    if name in secrets:
        del secrets[name]
        save_registry(reg)


def list_accounts() -> dict[str, dict]:
    """Local pointer metadata grouped by account - never values. Needs no session."""
    return load_registry().get("accounts", {})
