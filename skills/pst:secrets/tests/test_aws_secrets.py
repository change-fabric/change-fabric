"""Unit tests for the AWS SSM backend (v2 registry, argv-secret-free writes).

`_aws` is monkeypatched so no AWS calls happen; the registry path is redirected
to a temp file. Covers config resolution, ARN parsing, drawer namespacing, the
fetch CLI's shell quoting, and -- importantly -- that the secret value never
appears on the `aws` argv (it is piped via stdin).
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
import registry as r  # noqa: E402
import secret_fetch as f  # noqa: E402


@pytest.fixture
def reg_path(tmp_path, monkeypatch):
    path = tmp_path / "registry.json"
    monkeypatch.setattr(r, "REGISTRY_PATH", path)
    return path


@pytest.fixture
def cfg():
    return s.Config(profile="p", region="us-east-1", kms_key="alias/pst-secrets",
                    prefix="/pst-secrets")


def _fake_aws(results):
    calls = []

    def fake(cfg, *args, input_text=None):
        calls.append({"args": args, "input": input_text})
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
    assert s.Config.from_env(region="eu-central-1").region == "eu-central-1"


def test_ssm_path_joins_cleanly():
    c = s.Config(None, "us-east-1", "alias/k", "/pst-secrets/")
    assert c.ssm_path("FOO") == "/pst-secrets/FOO"


@pytest.mark.parametrize("arn,expected", [
    ("arn:aws:iam::569032832755:user/patrick", "569032832755"),
    ("arn:aws:sts::312850677788:assumed-role/Admin/x", "312850677788"),
    ("garbage", "unknown"),
    ("", "unknown"),
])
def test_account_of(arn, expected):
    assert s._account_of(arn) == expected


# ---------------------------------------------------------------- store / fetch

def test_put_does_not_leak_value_on_argv(reg_path, cfg, monkeypatch):
    fake = _fake_aws([])
    monkeypatch.setattr(s, "ensure_session", lambda c: "arn:aws:iam::111:user/x")
    monkeypatch.setattr(s, "_aws", fake)
    s.put_secret(cfg, "API_KEY", "topsecret", "my key")
    put_call = next(c for c in fake.calls if "put-parameter" in c["args"])
    assert "topsecret" not in put_call["args"]      # never on argv
    assert "topsecret" in (put_call["input"] or "")  # piped via stdin
    assert "--cli-input-json" in put_call["args"]


def test_put_and_get_round_trip_namespaced(reg_path, cfg, monkeypatch):
    monkeypatch.setattr(s, "ensure_session", lambda c: "arn:aws:iam::569032832755:user/p")
    monkeypatch.setattr(s, "_aws", _fake_aws([("get-parameter", 0, "topsecret\n", "")]))
    s.put_secret(cfg, "API_KEY", "topsecret", "my key")
    did = r.aws_drawer_id("569032832755", "us-east-1", "/pst-secrets")
    saved = json.loads(reg_path.read_text())
    assert saved["drawers"][did]["secrets"]["API_KEY"]["ssm_path"] == "/pst-secrets/API_KEY"
    assert s.get_secret(cfg, "API_KEY") == "topsecret"


def test_same_name_two_accounts_no_collision(reg_path, cfg, monkeypatch):
    monkeypatch.setattr(s, "_aws", _fake_aws([]))
    monkeypatch.setattr(s, "ensure_session", lambda c: "arn:aws:iam::111:user/a")
    s.put_secret(cfg, "TOKEN", "v-a")
    monkeypatch.setattr(s, "ensure_session", lambda c: "arn:aws:iam::222:user/b")
    s.put_secret(cfg, "TOKEN", "v-b")
    drawers = r.all_drawers()
    d1 = r.aws_drawer_id("111", "us-east-1", "/pst-secrets")
    d2 = r.aws_drawer_id("222", "us-east-1", "/pst-secrets")
    assert "TOKEN" in drawers[d1]["secrets"] and "TOKEN" in drawers[d2]["secrets"]


def test_delete_scopes_to_authenticated_account(reg_path, cfg, monkeypatch):
    monkeypatch.setattr(s, "_aws", _fake_aws([]))
    monkeypatch.setattr(s, "ensure_session", lambda c: "arn:aws:iam::111:user/a")
    s.put_secret(cfg, "TOKEN", "v-a")
    monkeypatch.setattr(s, "ensure_session", lambda c: "arn:aws:iam::222:user/b")
    s.put_secret(cfg, "TOKEN", "v-b")
    s.delete_secret(cfg, "TOKEN")  # authed to 222
    drawers = r.all_drawers()
    assert "TOKEN" in drawers[r.aws_drawer_id("111", "us-east-1", "/pst-secrets")]["secrets"]
    assert "TOKEN" not in drawers[r.aws_drawer_id("222", "us-east-1", "/pst-secrets")]["secrets"]


def test_put_raises_on_ssm_error(reg_path, cfg, monkeypatch):
    monkeypatch.setattr(s, "ensure_session", lambda c: "arn:aws:iam::1:user/x")
    monkeypatch.setattr(s, "_aws", _fake_aws([("put-parameter", 1, "", "boom")]))
    with pytest.raises(s.SecretError, match="boom"):
        s.put_secret(cfg, "K", "v")


def test_delete_tolerates_parameter_not_found(reg_path, cfg, monkeypatch):
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
