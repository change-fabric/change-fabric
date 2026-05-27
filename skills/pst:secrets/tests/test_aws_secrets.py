"""Unit tests for the pst:secrets AWS credential-drawer lib.

Covers the pure/local logic - registry migration, account namespacing, pointer
path resolution, ARN parsing, config resolution, and the fetch CLI's shell
quoting. No AWS calls: `put_secret`/`get_secret`/`delete_secret` are exercised
with `_aws` monkeypatched, so the suite is fast and runs anywhere.

Run:  pytest skills/pst:secrets/tests -q
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS))

import aws_secrets as s  # noqa: E402
import secret_fetch as f  # noqa: E402


@pytest.fixture
def registry(tmp_path, monkeypatch):
    """Redirect the module-level registry path to a temp file."""
    path = tmp_path / "registry.json"
    monkeypatch.setattr(s, "REGISTRY_PATH", path)
    return path


@pytest.fixture
def cfg():
    return s.Config(profile="p", region="us-east-1", kms_key="alias/pst-secrets",
                    prefix="/pst-secrets")


def _fake_aws(results):
    """Return an _aws stand-in that yields queued CompletedProcess results by argv match."""
    calls = []

    def fake(cfg, *args, input_text=None):
        calls.append(args)
        for matcher, rc, out, err in results:
            if matcher in args:
                return subprocess.CompletedProcess(args, rc, out, err)
        return subprocess.CompletedProcess(args, 0, "", "")

    fake.calls = calls
    return fake


# ---------------------------------------------------------------- Config

def test_config_from_env_defaults(monkeypatch):
    for k in ("PST_SECRETS_PROFILE", "PST_SECRETS_REGION",
              "PST_SECRETS_KMS_KEY", "PST_SECRETS_PREFIX"):
        monkeypatch.delenv(k, raising=False)
    c = s.Config.from_env()
    assert c.region == "us-east-1"
    assert c.kms_key == "alias/pst-secrets"
    assert c.prefix == "/pst-secrets"
    assert c.profile is None


def test_config_overrides_win_over_env(monkeypatch):
    monkeypatch.setenv("PST_SECRETS_REGION", "us-west-2")
    c = s.Config.from_env(region="eu-central-1")
    assert c.region == "eu-central-1"


def test_ssm_path_joins_cleanly():
    c = s.Config(None, "us-east-1", "alias/k", "/pst-secrets/")
    assert c.ssm_path("FOO") == "/pst-secrets/FOO"


# ---------------------------------------------------------------- ARN parsing

@pytest.mark.parametrize("arn,expected", [
    ("arn:aws:iam::569032832755:user/patrick", "569032832755"),
    ("arn:aws:sts::312850677788:assumed-role/Admin/x", "312850677788"),
    ("garbage", "unknown"),
    ("", "unknown"),
])
def test_account_of(arn, expected):
    assert s._account_of(arn) == expected


# ---------------------------------------------------------------- normalize

def test_flat_registry_is_folded_under_its_account(registry):
    registry.write_text(json.dumps({
        "account": "111122223333", "region": "us-east-1",
        "kms_key": "alias/pst-secrets",
        "secrets": {"LEGACY": {"ssm_path": "/pst-secrets/LEGACY", "label": "x", "updated": "t"}},
    }))
    reg = s.load_registry()
    assert reg["version"] == s.REGISTRY_VERSION
    assert reg["accounts"]["111122223333"]["secrets"]["LEGACY"]["label"] == "x"
    assert "secrets" not in reg  # flat key gone


def test_flat_empty_yields_no_accounts(registry):
    registry.write_text(json.dumps({"secrets": {}}))
    reg = s.load_registry()
    assert reg["accounts"] == {}


def test_load_missing_registry_is_empty(registry):
    reg = s.load_registry()
    assert reg["version"] == s.REGISTRY_VERSION and reg["accounts"] == {}


def test_already_namespaced_is_left_intact(registry):
    doc = {"version": 1, "backend": "aws-ssm",
           "accounts": {"1": {"region": "r", "kms_key": "k", "secrets": {}}}}
    registry.write_text(json.dumps(doc))
    assert s.load_registry()["accounts"]["1"]["kms_key"] == "k"


# ---------------------------------------------------------------- namespacing

def test_put_and_get_round_trip_namespaced(registry, cfg, monkeypatch):
    monkeypatch.setattr(s, "ensure_session",
                        lambda c: "arn:aws:iam::569032832755:user/patrick")
    monkeypatch.setattr(s, "_aws", _fake_aws([("get-parameter", 0, "topsecret\n", "")]))
    s.put_secret(cfg, "API_KEY", "topsecret", "my key")
    reg = json.loads(registry.read_text())
    assert reg["accounts"]["569032832755"]["secrets"]["API_KEY"]["ssm_path"] == "/pst-secrets/API_KEY"
    assert s.get_secret(cfg, "API_KEY") == "topsecret"  # rstrip trailing newline


def test_same_name_two_accounts_no_collision(registry, cfg, monkeypatch):
    monkeypatch.setattr(s, "_aws", _fake_aws([]))
    monkeypatch.setattr(s, "ensure_session", lambda c: "arn:aws:iam::111:user/a")
    s.put_secret(cfg, "TOKEN", "v-a")
    monkeypatch.setattr(s, "ensure_session", lambda c: "arn:aws:iam::222:user/b")
    s.put_secret(cfg, "TOKEN", "v-b")
    accounts = s.list_accounts()
    assert set(accounts) == {"111", "222"}
    assert "TOKEN" in accounts["111"]["secrets"]
    assert "TOKEN" in accounts["222"]["secrets"]


def test_delete_scopes_to_authenticated_account(registry, cfg, monkeypatch):
    monkeypatch.setattr(s, "_aws", _fake_aws([]))
    monkeypatch.setattr(s, "ensure_session", lambda c: "arn:aws:iam::111:user/a")
    s.put_secret(cfg, "TOKEN", "v-a")
    monkeypatch.setattr(s, "ensure_session", lambda c: "arn:aws:iam::222:user/b")
    s.put_secret(cfg, "TOKEN", "v-b")
    s.delete_secret(cfg, "TOKEN")  # authed to 222
    accounts = s.list_accounts()
    assert "TOKEN" in accounts["111"]["secrets"]   # 111 untouched
    assert "TOKEN" not in accounts["222"]["secrets"]  # 222 removed


def test_registered_path_falls_back_to_cfg(registry, cfg):
    reg = {"accounts": {}}
    assert s._registered_path(reg, "999", "UNKNOWN", cfg) == "/pst-secrets/UNKNOWN"


# ---------------------------------------------------------------- failures

def test_put_raises_on_ssm_error(registry, cfg, monkeypatch):
    monkeypatch.setattr(s, "ensure_session", lambda c: "arn:aws:iam::1:user/x")
    monkeypatch.setattr(s, "_aws", _fake_aws([("put-parameter", 1, "", "boom")]))
    with pytest.raises(s.SecretError, match="boom"):
        s.put_secret(cfg, "K", "v")


def test_delete_tolerates_parameter_not_found(registry, cfg, monkeypatch):
    monkeypatch.setattr(s, "ensure_session", lambda c: "arn:aws:iam::1:user/x")
    monkeypatch.setattr(s, "_aws",
                        _fake_aws([("delete-parameter", 255, "", "ParameterNotFound: nope")]))
    s.delete_secret(cfg, "GONE")  # must not raise


# ---------------------------------------------------------------- fetch CLI quoting

@pytest.mark.parametrize("value", ["plain", "with space", "has'quote", "$(evil)", "a;b|c"])
def test_shell_quote_round_trips_through_sh(value):
    quoted = f._shell_quote(value)
    out = subprocess.run(["sh", "-c", f"printf %s {quoted}"],
                         capture_output=True, text=True, check=True).stdout
    assert out == value
