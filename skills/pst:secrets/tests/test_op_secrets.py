"""Unit tests for the 1Password backend with the `op` subprocess stubbed.

Verifies: writes use an stdin JSON template (value never on argv), creates record
an item-ID pointer, an existing secret is edited not duplicated, reads prefer
`op read` and fall back to `op item get --format json`, and deletes archive +
drop the pointer.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS))

import op_secrets as op  # noqa: E402
import registry as r  # noqa: E402


@pytest.fixture
def reg_path(tmp_path, monkeypatch):
    path = tmp_path / "registry.json"
    monkeypatch.setattr(r, "REGISTRY_PATH", path)
    return path


def fake_op(rules):
    """rules: list of (needle_in_args, rc, stdout, stderr). First match wins."""
    calls = []

    def fake(*args, input_text=None):
        calls.append({"args": args, "input": input_text})
        for needle, rc, out, err in rules:
            if needle in args:
                return subprocess.CompletedProcess(args, rc, out, err)
        return subprocess.CompletedProcess(args, 0, "", "")

    fake.calls = calls
    return fake


def backend():
    return op.OnePasswordBackend(
        account_selector="my.1password.com", account_id="ACCT1",
        vault_id="VAULT1", vault_name="Private")


def test_put_creates_item_via_stdin_template(reg_path, monkeypatch):
    fake = fake_op([
        ("list", 0, "[]", ""),
        ("create", 0, json.dumps({"id": "item-123"}), ""),
    ])
    monkeypatch.setattr(op, "_op", fake)
    backend().put("LINEAR_API_KEY", "s3cr3t", "API Key")
    create = next(c for c in fake.calls if "create" in c["args"])
    assert "s3cr3t" not in create["args"]          # not on argv
    assert "s3cr3t" in (create["input"] or "")      # piped on stdin
    assert "-" in create["args"]                     # stdin template marker
    ptr = r.get_pointer(r.op_drawer_id("ACCT1", "VAULT1"), "LINEAR_API_KEY")
    assert ptr["item_id"] == "item-123" and ptr["field"] == "credential"


def test_put_existing_edits_not_duplicates(reg_path, monkeypatch):
    r.put_pointer(r.op_drawer_id("ACCT1", "VAULT1"), "K",
                  {"item_id": "item-existing", "field": "credential"},
                  backend="op", account_id="ACCT1", account="my.1password.com",
                  vault_id="VAULT1", vault="Private")
    fake = fake_op([("list", 0, "[]", ""), ("edit", 0, json.dumps({"id": "item-existing"}), "")])
    monkeypatch.setattr(op, "_op", fake)
    backend().put("K", "newval")
    assert any("edit" in c["args"] for c in fake.calls)
    assert not any("create" in c["args"] for c in fake.calls)
    edit = next(c for c in fake.calls if "edit" in c["args"])
    assert "newval" not in edit["args"] and "newval" in (edit["input"] or "")


def test_get_prefers_op_read(reg_path, monkeypatch):
    r.put_pointer(r.op_drawer_id("ACCT1", "VAULT1"), "K",
                  {"item_id": "item-9", "field": "credential"},
                  backend="op", account_id="ACCT1", account="my.1password.com",
                  vault_id="VAULT1", vault="Private")
    fake = fake_op([("list", 0, "[]", ""), ("read", 0, "the-value\n", "")])
    monkeypatch.setattr(op, "_op", fake)
    assert backend().get("K") == "the-value"
    read = next(c for c in fake.calls if "read" in c["args"])
    assert "op://VAULT1/item-9/credential" in read["args"]


def test_get_falls_back_to_item_get_json(reg_path, monkeypatch):
    r.put_pointer(r.op_drawer_id("ACCT1", "VAULT1"), "K",
                  {"item_id": "item-9", "field": "credential"},
                  backend="op", account_id="ACCT1", account="my.1password.com",
                  vault_id="VAULT1", vault="Private")
    item_json = json.dumps({"id": "item-9",
                            "fields": [{"id": "credential", "value": "fallback-val"}]})
    fake = fake_op([
        ("list", 0, "[]", ""),
        ("read", 1, "", "reference not found"),
        ("get", 0, item_json, ""),
    ])
    monkeypatch.setattr(op, "_op", fake)
    assert backend().get("K") == "fallback-val"


def test_delete_archives_and_drops_pointer(reg_path, monkeypatch):
    did = r.op_drawer_id("ACCT1", "VAULT1")
    r.put_pointer(did, "K", {"item_id": "item-9", "field": "credential"},
                  backend="op", account_id="ACCT1", account="my.1password.com",
                  vault_id="VAULT1", vault="Private")
    fake = fake_op([("list", 0, "[]", ""), ("delete", 0, "", "")])
    monkeypatch.setattr(op, "_op", fake)
    backend().delete("K")
    delete = next(c for c in fake.calls if "delete" in c["args"])
    assert "--archive" in delete["args"]
    assert r.get_pointer(did, "K") is None


def test_get_unknown_secret_raises(reg_path, monkeypatch):
    monkeypatch.setattr(op, "_op", fake_op([("list", 0, "[]", "")]))
    with pytest.raises(op.OpError, match="No secret"):
        backend().get("MISSING")
