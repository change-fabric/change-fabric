"""Unit tests for catalog discovery, overlays, resolution, and semantics."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS))

import config as C  # noqa: E402


@pytest.fixture
def cfg_path(tmp_path, monkeypatch):
    path = tmp_path / "config.json"
    monkeypatch.setattr(C, "CONFIG_PATH", path)
    return path


def make_catalog():
    personal = C.OpAccount(id="A1", alias="personal", selector="my.1password.com",
                           url="my.1password.com")
    personal.vaults["V1"] = C.OpVault(id="V1", name="Private", alias="private",
                                      semantic_labels=["personal private"])
    family = C.OpAccount(id="A2", alias="family", selector="fam.1password.com",
                         url="fam.1password.com")
    family.vaults["V3"] = C.OpVault(id="V3", name="Shared (Patrick & wife)",
                                    alias="shared", semantic_labels=["family shared"])
    aws = C.AwsAccount(name="personal-aws", aws_profile="pstaylor-mfa")
    return C.Catalog(
        default_profile="personal-private",
        op_accounts={"A1": personal, "A2": family},
        aws_accounts={"personal-aws": aws},
        profiles={
            "personal-private": C.Profile("personal-private", "op", "personal", "private"),
            "family-shared": C.Profile("family-shared", "op", "family", "shared"),
            "aws": C.Profile("aws", "aws-ssm", "personal-aws", ""),
        },
        trusted_overlay_roots=["~/workspaces"],
    )


# ---------------------------------------------------------------- roundtrip

def test_catalog_save_load_roundtrip(cfg_path):
    C.save_catalog(make_catalog())
    loaded = C.load_catalog()
    assert loaded.default_profile == "personal-private"
    assert loaded.op_accounts["A2"].vaults["V3"].alias == "shared"
    assert oct(cfg_path.stat().st_mode)[-3:] == "600"


def test_duplicate_account_alias_rejected(cfg_path):
    cat = make_catalog()
    cat.op_accounts["A2"].alias = "personal"  # collide with A1
    with pytest.raises(C.ConfigError, match="alias"):
        C.save_catalog(cat)


# ---------------------------------------------------------------- discovery

def test_discover_op_merges_preserving_aliases(monkeypatch):
    def fake_op(*args):
        if args[0] == "account":
            return subprocess.CompletedProcess(args, 0, json.dumps(
                [{"account_uuid": "A1", "url": "my.1password.com", "email": "p@x.com"}]), "")
        if args[0] == "vault":
            return subprocess.CompletedProcess(args, 0, json.dumps(
                [{"id": "V1", "name": "Private"}, {"id": "V9", "name": "NewVault"}]), "")
        return subprocess.CompletedProcess(args, 0, "", "")
    monkeypatch.setattr(C, "_op", fake_op)

    cat = make_catalog()  # A1 already has V1 aliased 'private'
    discovered = C.discover_op()
    C.refresh_catalog(cat, discovered, "2026-05-28T00:00:00+00:00")
    a1 = cat.op_accounts["A1"]
    assert a1.vaults["V1"].alias == "private"          # human alias preserved
    assert a1.vaults["V9"].name == "NewVault"          # new vault added
    assert a1.last_seen == "2026-05-28T00:00:00+00:00"
    # A2 not in discovery -> marked missing, not deleted
    assert cat.op_accounts["A2"].missing_since == "2026-05-28T00:00:00+00:00"


def test_discover_op_empty_raises(monkeypatch):
    monkeypatch.setattr(C, "_op", lambda *a: subprocess.CompletedProcess(a, 0, "[]", ""))
    with pytest.raises(C.ConfigError, match="Integrate with 1Password CLI"):
        C.discover_op()


# ---------------------------------------------------------------- overlays

def test_overlay_under_trusted_root_is_used(tmp_path, monkeypatch):
    cat = make_catalog()
    cat.trusted_overlay_roots = [str(tmp_path)]
    proj = tmp_path / "clients" / "acme"
    proj.mkdir(parents=True)
    (proj / C.OVERLAY_FILENAME).write_text(json.dumps({"profile": "family-shared"}))
    found = C.find_overlay(proj, cat)
    assert found is not None and found[1]["profile"] == "family-shared"


def test_overlay_outside_trusted_root_ignored(tmp_path, monkeypatch):
    cat = make_catalog()
    cat.trusted_overlay_roots = [str(tmp_path / "trusted")]
    rogue = tmp_path / "rogue"
    rogue.mkdir(parents=True)
    (rogue / C.OVERLAY_FILENAME).write_text(json.dumps({"profile": "family-shared"}))
    assert C.find_overlay(rogue, cat) is None


# ---------------------------------------------------------------- resolution

def test_resolve_default_profile():
    cat = make_catalog()
    res = C.resolve(cat, None, C.ResolveFlags())
    assert res.backend == "op" and res.op_vault_id == "V1"
    assert res.drawer_id == "op:acct:A1:vault:V1"
    assert "default profile" in res.source


def test_resolve_overlay_beats_default():
    cat = make_catalog()
    res = C.resolve(cat, {"profile": "family-shared"}, C.ResolveFlags(),
                    overlay_source="/x/.pst-secrets.json")
    assert res.op_account_id == "A2" and res.op_vault_id == "V3"


def test_resolve_flag_beats_overlay():
    cat = make_catalog()
    res = C.resolve(cat, {"profile": "family-shared"},
                    C.ResolveFlags(profile="personal-private"))
    assert res.op_account_id == "A1"


def test_resolve_aws_flag():
    cat = make_catalog()
    res = C.resolve(cat, None, C.ResolveFlags(aws=True))
    assert res.backend == "aws-ssm" and res.aws_account_name == "personal-aws"


def test_resolve_account_requires_vault():
    cat = make_catalog()
    with pytest.raises(C.ConfigError, match="also pass --vault"):
        C.resolve(cat, None, C.ResolveFlags(account="family"))


def test_resolve_unknown_profile_raises():
    cat = make_catalog()
    with pytest.raises(C.ConfigError, match="Unknown profile"):
        C.resolve(cat, None, C.ResolveFlags(profile="nope"))


# ---------------------------------------------------------------- semantic

def test_semantic_family_shared():
    cat = make_catalog()
    res = C.resolve(cat, None, C.ResolveFlags(semantic="family shared"))
    assert res.op_account_id == "A2" and res.op_vault_id == "V3"


def test_semantic_ignores_filler_words():
    cat = make_catalog()
    # "the …​ vault" filler must not block the match
    res = C.resolve(cat, None, C.ResolveFlags(semantic="the family shared vault"))
    assert res.op_account_id == "A2" and res.op_vault_id == "V3"


def test_semantic_no_match_raises():
    cat = make_catalog()
    with pytest.raises(C.ConfigError, match="Could not match"):
        C.resolve(cat, None, C.ResolveFlags(semantic="nonexistent vault xyz"))


def test_semantic_exact_alias_wins():
    cat = make_catalog()
    res = C.resolve(cat, None, C.ResolveFlags(semantic="private"))
    assert res.op_vault_id == "V1"


def test_missing_account_excluded_from_semantic():
    cat = make_catalog()
    cat.op_accounts["A2"].missing_since = "2026-01-01T00:00:00+00:00"
    with pytest.raises(C.ConfigError):
        C.resolve(cat, None, C.ResolveFlags(semantic="family shared"))
