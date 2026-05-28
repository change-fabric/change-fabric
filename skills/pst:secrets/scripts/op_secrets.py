#!/usr/bin/env python3
"""1Password-backed secret storage for the pst:secrets credential drawer.

One 1Password item per secret: the item *title* is the ENV name and the value
lives in a single concealed field we define ourselves (so reads never depend on
a built-in template field whose name we could not verify offline). The local
pointer registry records the item ID + field name, so reads/deletes address the
item by ID -- immune to duplicate titles and renames.

Security posture (honest, weaker than the AWS KMS MFA-deny gate): access is
governed by the 1Password app / CLI unlock state, not a server-side policy that
re-checks MFA on every read. If the desktop app is already unlocked and CLI
integration is enabled, a local process running as the user can `op read`
without a fresh prompt. This is an ergonomic *personal* drawer, not a
service-secret store.

Secret values are passed to `op` only via an stdin JSON template (writes) or
read back on stdout (reads) -- never on argv, never to a temp file.
"""
from __future__ import annotations

import json
import subprocess

from registry import delete_pointer, get_pointer, now_iso, op_drawer_id, put_pointer

# These describe the item we *create*; because we set the field explicitly they
# do not depend on 1Password's built-in API Credential template. Verify/adjust
# once desktop CLI integration is enabled (Phase 1 smoke test).
OP_CATEGORY = "API_CREDENTIAL"
OP_FIELD = "credential"

__all__ = ["OpError", "OnePasswordBackend"]


class OpError(RuntimeError):
    """Raised for any 1Password operation failure, with a human-actionable hint."""


def _op(*args: str, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    """Single subprocess seam for the `op` CLI (stub in tests)."""
    return subprocess.run(
        ["op", *args], input=input_text, capture_output=True, text=True, check=False
    )


class OnePasswordBackend:
    def __init__(self, account_selector: str, account_id: str,
                 vault_id: str, vault_name: str = "") -> None:
        self.account_selector = account_selector
        self.account_id = account_id
        self.vault_id = vault_id
        self.vault_name = vault_name

    @property
    def drawer_id(self) -> str:
        return op_drawer_id(self.account_id, self.vault_id)

    def _drawer_fields(self) -> dict:
        return {"backend": "op", "account_id": self.account_id,
                "account": self.account_selector, "vault_id": self.vault_id,
                "vault": self.vault_name}

    # -- session -------------------------------------------------------------

    def ensure_session(self) -> None:
        # Under desktop-app CLI integration there is often no `op signin` session
        # (so `op whoami` reports "not signed in") even though data commands are
        # authorized on demand. Probe with a real read instead of trusting whoami.
        res = _op("vault", "list", "--account", self.account_selector, "--format=json")
        if res.returncode != 0:
            raise OpError(
                f"1Password is not reachable for account '{self.account_selector}'.\n"
                "Unlock the desktop app (or run `op signin`), confirm "
                "Settings -> Developer -> \"Integrate with 1Password CLI\" is on, "
                "then retry.\n" + res.stderr.strip()
            )

    # -- write ---------------------------------------------------------------

    def put(self, name: str, value: str, label: str | None = None) -> None:
        self.ensure_session()
        existing = get_pointer(self.drawer_id, name)
        if existing:
            self._edit(existing["item_id"], value)
            item_id, field = existing["item_id"], existing.get("field", OP_FIELD)
        else:
            item_id, field = self._create(name, value, label)
        put_pointer(
            self.drawer_id, name,
            {"item_id": item_id, "field": field, "label": label or name,
             "updated": now_iso()},
            **self._drawer_fields(),
        )

    def _create(self, name: str, value: str, label: str | None) -> tuple[str, str]:
        template = {
            "title": name,
            "category": OP_CATEGORY,
            "fields": [
                {"id": OP_FIELD, "type": "CONCEALED",
                 "label": label or OP_FIELD, "value": value},
            ],
        }
        res = _op("item", "create", "--account", self.account_selector,
                  "--vault", self.vault_id, "--format=json", "-",
                  input_text=json.dumps(template))
        if res.returncode != 0:
            raise OpError(f"Failed to create 1Password item '{name}':\n{res.stderr.strip()}")
        item = json.loads(res.stdout or "{}")
        item_id = item.get("id")
        if not item_id:
            raise OpError(f"1Password did not return an item ID for '{name}'.")
        return item_id, OP_FIELD

    def _edit(self, item_id: str, value: str) -> None:
        # Assignment statements appear in argv/history, so set the value via an
        # stdin-piped edit template rather than `field=value` on the command line.
        template = {"fields": [{"id": OP_FIELD, "type": "CONCEALED", "value": value}]}
        res = _op("item", "edit", item_id, "--account", self.account_selector,
                  "--vault", self.vault_id, "--format=json", "-",
                  input_text=json.dumps(template))
        if res.returncode != 0:
            raise OpError(f"Failed to update 1Password item '{item_id}':\n{res.stderr.strip()}")

    # -- read ----------------------------------------------------------------

    def get(self, name: str) -> str:
        self.ensure_session()
        pointer = get_pointer(self.drawer_id, name)
        if not pointer:
            raise OpError(f"No secret '{name}' registered in {self.drawer_id}.")
        item_id, field = pointer["item_id"], pointer.get("field", OP_FIELD)
        ref = f"op://{self.vault_id}/{item_id}/{field}"
        res = _op("read", "--account", self.account_selector, ref)
        if res.returncode == 0:
            return res.stdout.rstrip("\n")
        return self._get_via_item(item_id, field, fallback_err=res.stderr)

    def _get_via_item(self, item_id: str, field: str, fallback_err: str) -> str:
        res = _op("item", "get", item_id, "--account", self.account_selector,
                  "--vault", self.vault_id, "--format=json", "--reveal")
        if res.returncode != 0:
            raise OpError("Failed to read secret from 1Password.\n"
                          + (fallback_err or res.stderr).strip())
        item = json.loads(res.stdout or "{}")
        for f in item.get("fields", []):
            if f.get("id") == field or f.get("label") == field:
                return f.get("value", "")
        raise OpError(f"Field '{field}' not found on 1Password item {item_id}.")

    # -- delete --------------------------------------------------------------

    def delete(self, name: str) -> None:
        self.ensure_session()
        pointer = get_pointer(self.drawer_id, name)
        if pointer:
            res = _op("item", "delete", pointer["item_id"],
                      "--account", self.account_selector, "--vault", self.vault_id,
                      "--archive")
            if res.returncode != 0 and "isn't an item" not in res.stderr \
                    and "not found" not in res.stderr.lower():
                raise OpError(f"Failed to delete 1Password item for '{name}':\n"
                              f"{res.stderr.strip()}")
        delete_pointer(self.drawer_id, name)
