"""Unit tests for the session-scoped secret cache.

Verifies: duration parsing, materialize writes 0600 files in a 0700 dir with the
values in the JSON store and `export` lines in the .env, lookup hits/misses,
lazy expiry purges, `end`/`purge` shred both files, warm-on-miss, and the
secret_fetch read path prefers a live cache (and --fresh bypasses it).

The watchdog is disabled via PST_SECRETS_NO_WATCHDOG so tests never spawn a
detached sleeper.
"""
from __future__ import annotations

import datetime as _dt
import json
import os
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS))

import session_cache as sc  # noqa: E402


@pytest.fixture(autouse=True)
def cache_env(tmp_path, monkeypatch):
    monkeypatch.setenv("PST_SECRETS_SESSION_DIR", str(tmp_path / "sess"))
    monkeypatch.setenv("PST_SECRETS_NO_WATCHDOG", "1")
    return tmp_path


# ---------------------------------------------------------------- durations

@pytest.mark.parametrize("spec,seconds", [
    ("12h", 12 * 3600),
    ("45m", 45 * 60),
    ("30s", 30),
    ("1h30m", 5400),
    ("1d", 86400),
    ("90", 90 * 60),  # bare integer == minutes
])
def test_parse_duration_ok(spec, seconds):
    assert sc.parse_duration(spec) == seconds


@pytest.mark.parametrize("spec", ["", "h", "12x", "1h30", "abc", "-5m"])
def test_parse_duration_rejects_garbage(spec):
    with pytest.raises(ValueError):
        sc.parse_duration(spec)


# ---------------------------------------------------------------- materialize

def test_materialize_writes_private_files_and_values():
    sc.materialize({"LINEAR_API_KEY": "s3cr3t"}, {"LINEAR_API_KEY": "op:acct:A:vault:V"})
    cache, env = sc.cache_paths()

    assert cache.exists() and env.exists()
    assert (cache.stat().st_mode & 0o777) == 0o600
    assert (env.stat().st_mode & 0o777) == 0o600
    assert (sc.session_dir().stat().st_mode & 0o777) == 0o700

    meta = json.loads(cache.read_text())
    assert meta["values"]["LINEAR_API_KEY"] == "s3cr3t"
    assert meta["drawers"]["LINEAR_API_KEY"] == "op:acct:A:vault:V"

    assert "export LINEAR_API_KEY='s3cr3t'" in env.read_text()


def test_env_render_shell_quotes_tricky_values():
    sc.materialize({"K": "a'b c$x"}, {})
    _, env = sc.cache_paths()
    assert "export K='a'\"'\"'b c$x'" in env.read_text()


def test_lookup_hit_and_miss():
    sc.materialize({"A": "1"}, {})
    assert sc.lookup("A") == "1"
    assert sc.lookup("MISSING") is None


def test_lookup_none_without_session():
    assert sc.lookup("A") is None
    assert sc.is_live() is False


# ---------------------------------------------------------------- expiry

def test_expired_session_is_purged_on_access(monkeypatch):
    sc.materialize({"A": "1"}, {}, ttl_seconds=3600)
    cache, env = sc.cache_paths()
    meta = json.loads(cache.read_text())
    past = (sc._now() - _dt.timedelta(hours=1)).isoformat(timespec="seconds")
    meta["expires_at"] = past
    cache.write_text(json.dumps(meta))

    assert sc.load_session() is None
    assert not cache.exists()
    assert not env.exists()


def test_unparseable_expiry_fails_closed():
    sc.materialize({"A": "1"}, {})
    cache, _ = sc.cache_paths()
    meta = json.loads(cache.read_text())
    meta["expires_at"] = "not-a-date"
    cache.write_text(json.dumps(meta))
    assert sc.load_session() is None


# ---------------------------------------------------------------- purge / warm

def test_purge_shreds_both_files():
    sc.materialize({"A": "1"}, {})
    cache, env = sc.cache_paths()
    assert sc.purge("test") is True
    assert not cache.exists() and not env.exists()
    assert sc.purge("test") is False  # idempotent


def test_warm_adds_to_live_session_and_rerenders_env():
    sc.materialize({"A": "1"}, {})
    assert sc.warm("B", "2", "op:acct:A:vault:V") is True
    assert sc.lookup("B") == "2"
    _, env = sc.cache_paths()
    assert "export B='2'" in env.read_text()


def test_warm_is_noop_without_session():
    assert sc.warm("B", "2") is False
    assert sc.lookup("B") is None


def test_status_reports_names_not_values():
    sc.materialize({"A": "VALUE-AAA", "B": "VALUE-BBB"}, {})
    info = sc.status()
    assert info is not None
    assert info["names"] == ["A", "B"]
    dumped = json.dumps(info)
    assert "VALUE-AAA" not in dumped and "VALUE-BBB" not in dumped


# ---------------------------------------------------------------- watchdog rotation

def test_watchdog_skips_when_token_rotated():
    sc.materialize({"A": "1"}, {})
    # Simulate a stale watchdog from a previous session firing after re-materialize.
    sc._run_watchdog(deadline_epoch=0, token="stale-token")
    cache, _ = sc.cache_paths()
    assert cache.exists()  # current session untouched


# ---------------------------------------------------------------- fetch path

class _FakeBackend:
    drawer_id = "op:acct:A:vault:V"

    def __init__(self):
        self.calls = 0

    def get(self, name):
        self.calls += 1
        return f"backend-{name}"


def test_fetch_prefers_live_cache(monkeypatch, capsys):
    import secret_fetch as sf

    sc.materialize({"LINEAR_API_KEY": "cached"}, {})
    fake = _FakeBackend()
    monkeypatch.setattr(sf, "locate_backend", lambda *a, **k: fake)

    rc = sf.main(["get", "LINEAR_API_KEY"]) if hasattr(sf, "main") else None
    out = capsys.readouterr().out
    assert out == "cached"
    assert fake.calls == 0  # backend never touched


def test_fetch_fresh_bypasses_cache(monkeypatch, capsys):
    import secret_fetch as sf

    sc.materialize({"LINEAR_API_KEY": "cached"}, {})
    fake = _FakeBackend()
    monkeypatch.setattr(sf, "locate_backend", lambda *a, **k: fake)

    sf.main(["get", "--fresh", "LINEAR_API_KEY"])
    out = capsys.readouterr().out
    assert out == "backend-LINEAR_API_KEY"
    assert fake.calls == 1


def test_fetch_warms_on_miss(monkeypatch, capsys):
    import secret_fetch as sf

    sc.materialize({"OTHER": "x"}, {})  # live session, but missing our key
    fake = _FakeBackend()
    monkeypatch.setattr(sf, "locate_backend", lambda *a, **k: fake)

    sf.main(["get", "OPENAI_API_KEY"])
    assert capsys.readouterr().out == "backend-OPENAI_API_KEY"
    assert sc.lookup("OPENAI_API_KEY") == "backend-OPENAI_API_KEY"  # warmed
