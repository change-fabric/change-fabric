"""Unit tests for the shared v2 pointer registry + migrations."""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS))

import registry as r  # noqa: E402


@pytest.fixture
def reg_path(tmp_path, monkeypatch):
    path = tmp_path / "registry.json"
    monkeypatch.setattr(r, "REGISTRY_PATH", path)
    return path


def test_missing_registry_is_empty_v2(reg_path):
    reg = r.load_registry()
    assert reg["version"] == 2 and reg["drawers"] == {}


def test_v1_accounts_migrates_to_aws_drawer(reg_path):
    reg_path.write_text(json.dumps({
        "version": 1, "backend": "aws-ssm",
        "accounts": {"569032832755": {
            "region": "us-east-1", "kms_key": "alias/pst-secrets",
            "secrets": {"LEGACY": {"ssm_path": "/pst-secrets/LEGACY",
                                   "label": "x", "updated": "t"}}}},
    }))
    reg = r.load_registry()
    did = r.aws_drawer_id("569032832755", "us-east-1", "/pst-secrets")
    assert reg["version"] == 2
    assert reg["drawers"][did]["secrets"]["LEGACY"]["label"] == "x"
    assert "accounts" not in reg


def test_v0_flat_migrates(reg_path):
    reg_path.write_text(json.dumps({
        "account": "111", "region": "us-east-1", "kms_key": "alias/k",
        "secrets": {"OLD": {"ssm_path": "/pst-secrets/OLD", "label": "y", "updated": "t"}},
    }))
    reg = r.load_registry()
    did = r.aws_drawer_id("111", "us-east-1", "/pst-secrets")
    assert reg["drawers"][did]["secrets"]["OLD"]["label"] == "y"


def test_v0_empty_yields_no_drawers(reg_path):
    reg_path.write_text(json.dumps({"secrets": {}}))
    assert r.load_registry()["drawers"] == {}


def test_v2_left_intact(reg_path):
    doc = {"version": 2, "drawers": {"op:acct:A:vault:V": {
        "backend": "op", "account_id": "A", "vault_id": "V", "secrets": {}}}}
    reg_path.write_text(json.dumps(doc))
    assert r.load_registry()["drawers"]["op:acct:A:vault:V"]["backend"] == "op"


def test_put_get_delete_pointer_roundtrip(reg_path):
    did = r.op_drawer_id("ACCT", "VAULT")
    r.put_pointer(did, "LINEAR_API_KEY", {"item_id": "i1", "field": "credential"},
                  backend="op", account_id="ACCT", account="my.1password.com",
                  vault_id="VAULT", vault="Private")
    ptr = r.get_pointer(did, "LINEAR_API_KEY")
    assert ptr["item_id"] == "i1" and "updated" in ptr
    saved = json.loads(reg_path.read_text())
    assert saved["drawers"][did]["vault"] == "Private"
    assert r.delete_pointer(did, "LINEAR_API_KEY") is True
    assert r.get_pointer(did, "LINEAR_API_KEY") is None


def test_same_name_two_drawers_no_collision(reg_path):
    d1 = r.op_drawer_id("A1", "V1")
    d2 = r.op_drawer_id("A2", "V2")
    r.put_pointer(d1, "TOKEN", {"item_id": "x"}, backend="op", account_id="A1", vault_id="V1")
    r.put_pointer(d2, "TOKEN", {"item_id": "y"}, backend="op", account_id="A2", vault_id="V2")
    drawers = r.all_drawers()
    assert drawers[d1]["secrets"]["TOKEN"]["item_id"] == "x"
    assert drawers[d2]["secrets"]["TOKEN"]["item_id"] == "y"


def test_file_is_chmod_600(reg_path):
    r.put_pointer(r.op_drawer_id("A", "V"), "K", {"item_id": "i"},
                  backend="op", account_id="A", vault_id="V")
    assert oct(reg_path.stat().st_mode)[-3:] == "600"
