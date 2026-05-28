#!/usr/bin/env python3
"""AWS-backed secret storage for the pst:secrets credential drawer.

Secrets are stored as KMS-encrypted SSM Parameter Store *SecureString* values.
The plaintext never lands on disk -- only a local *pointer registry* (see
`registry.py`) mapping each logical name to its SSM path is kept locally.
Decryption requires a live AWS session (in practice an MFA-gated one minted by
/aws-mfa); the KMS key policy additionally denies decrypt without MFA, so even
leaked long-lived credentials cannot decrypt.

This module is intentionally generic (no account/region baked in). Callers
configure it via env vars or explicit kwargs:

  PST_SECRETS_PROFILE   AWS CLI profile to use            (default: AWS default chain)
  PST_SECRETS_REGION    AWS region                        (default: us-east-1)
  PST_SECRETS_KMS_KEY   KMS key id/alias for SecureString (default: alias/pst-secrets)
  PST_SECRETS_PREFIX    SSM parameter name prefix         (default: /pst-secrets)

It shells out to the `aws` CLI rather than taking a boto3 dependency.
"""
from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass

from registry import (
    aws_drawer_id,
    delete_pointer,
    get_drawer,
    get_pointer,
    load_registry,
    now_iso,
    put_pointer,
)

__all__ = [
    "Config",
    "SecretError",
    "ensure_session",
    "put_secret",
    "get_secret",
    "delete_secret",
    "AwsSsmBackend",
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


def _drawer_id(cfg: Config, account: str) -> str:
    return aws_drawer_id(account, cfg.region, cfg.prefix)


def _drawer_fields(cfg: Config, account: str) -> dict:
    return {"backend": "aws-ssm", "account_id": account, "region": cfg.region,
            "kms_key": cfg.kms_key, "prefix": cfg.prefix}


def _registered_path(account: str, name: str, cfg: Config) -> str:
    pointer = get_pointer(_drawer_id(cfg, account), name)
    return (pointer or {}).get("ssm_path") or cfg.ssm_path(name)


def put_secret(cfg: Config, name: str, value: str, label: str | None = None) -> None:
    """Encrypt+store one secret as a SecureString and record a local pointer.

    The value is passed via `--cli-input-json` on stdin (not `--value` on argv),
    so it never appears in the process list or shell history.
    """
    account = _account_of(ensure_session(cfg))
    payload = {
        "Name": cfg.ssm_path(name),
        "Type": "SecureString",
        "KeyId": cfg.kms_key,
        "Overwrite": True,
        "Value": value,
    }
    res = _aws(
        cfg, "ssm", "put-parameter",
        "--cli-input-json", "file:///dev/stdin",
        "--output", "json",
        input_text=json.dumps(payload),
    )
    if res.returncode != 0:
        raise SecretError(f"Failed to store '{name}' in SSM:\n{res.stderr.strip()}")
    put_pointer(
        _drawer_id(cfg, account), name,
        {"ssm_path": cfg.ssm_path(name), "label": label or name, "updated": now_iso()},
        **_drawer_fields(cfg, account),
    )


def get_secret(cfg: Config, name: str) -> str:
    """Fetch+decrypt one secret from the authenticated account. Returns plaintext."""
    account = _account_of(ensure_session(cfg))
    path = _registered_path(account, name, cfg)
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
    path = _registered_path(account, name, cfg)
    res = _aws(cfg, "ssm", "delete-parameter", "--name", path)
    if res.returncode != 0 and "ParameterNotFound" not in res.stderr:
        raise SecretError(f"Failed to delete '{name}' from SSM:\n{res.stderr.strip()}")
    delete_pointer(_drawer_id(cfg, account), name)


class AwsSsmBackend:
    """SecretBackend adapter over the env-driven AWS SSM functions."""

    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self._account: str | None = None

    @property
    def drawer_id(self) -> str:
        # Best-effort before auth; the registry write resolves the real account.
        return _drawer_id(self.cfg, self._account or "unknown")

    def ensure_session(self) -> None:
        self._account = _account_of(ensure_session(self.cfg))

    def put(self, name: str, value: str, label: str | None = None) -> None:
        put_secret(self.cfg, name, value, label)

    def get(self, name: str) -> str:
        return get_secret(self.cfg, name)

    def delete(self, name: str) -> None:
        delete_secret(self.cfg, name)
