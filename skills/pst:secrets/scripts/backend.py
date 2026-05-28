#!/usr/bin/env python3
"""Backend abstraction for the pst:secrets credential drawer.

A `SecretBackend` stores/fetches one named secret in a single drawer (a concrete
1Password account+vault, or one AWS account+region+prefix). `get_backend` turns
a resolved destination (`config.Resolution`) into the right adapter. Listing is
deliberately *not* a backend method -- it reads the local pointer registry only,
so `list` never needs to unlock anything.
"""
from __future__ import annotations

from typing import Protocol, runtime_checkable

__all__ = ["SecretBackend", "get_backend", "backend_from_drawer"]


@runtime_checkable
class SecretBackend(Protocol):
    drawer_id: str

    def ensure_session(self) -> None: ...
    def put(self, name: str, value: str, label: str | None = None) -> None: ...
    def get(self, name: str) -> str: ...
    def delete(self, name: str) -> None: ...


def get_backend(resolution: "object") -> SecretBackend:
    """Build the backend adapter for a `config.Resolution`."""
    backend = getattr(resolution, "backend", None)
    if backend == "op":
        from op_secrets import OnePasswordBackend
        return OnePasswordBackend(
            account_selector=resolution.op_account_selector,
            account_id=resolution.op_account_id,
            vault_id=resolution.op_vault_id,
            vault_name=resolution.op_vault_name,
        )
    if backend == "aws-ssm":
        from aws_secrets import AwsSsmBackend, Config
        cfg = Config.from_env(
            profile=resolution.aws_profile or None,
            region=resolution.aws_region or None,
            kms_key=resolution.aws_kms_key or None,
            prefix=resolution.aws_prefix or None,
        )
        return AwsSsmBackend(cfg)
    raise ValueError(f"Unknown backend: {backend!r}")


def backend_from_drawer(drawer: dict) -> SecretBackend:
    """Build the backend adapter for a registry drawer (read/delete path)."""
    if drawer.get("backend") == "op":
        from op_secrets import OnePasswordBackend
        return OnePasswordBackend(
            account_selector=drawer.get("account", ""),
            account_id=drawer.get("account_id", ""),
            vault_id=drawer.get("vault_id", ""),
            vault_name=drawer.get("vault", ""),
        )
    from aws_secrets import AwsSsmBackend, Config
    cfg = Config.from_env(
        region=drawer.get("region") or None,
        kms_key=drawer.get("kms_key") or None,
        prefix=drawer.get("prefix") or None,
    )
    return AwsSsmBackend(cfg)
