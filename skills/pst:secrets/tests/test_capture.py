"""Tests for script-owned confirm-on-write in secret_capture."""
from __future__ import annotations

import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS))

import secret_capture as cap  # noqa: E402


class _Resolution:
    drawer_id = "op:acct:A1:vault:V1"

    def describe(self):
        return "op / personal / Private [from default profile]"


def _args(**kw):
    base = dict(confirm_destination=None)
    base.update(kw)
    return SimpleNamespace(**base)


def test_noninteractive_requires_confirm_destination(monkeypatch, capsys):
    monkeypatch.setattr(cap.sys.stdin, "isatty", lambda: False)
    ok = cap._confirm_destination(_Resolution(), _args())
    assert ok is False
    err = capsys.readouterr().err
    assert "--confirm-destination op:acct:A1:vault:V1" in err


def test_confirm_destination_must_match(capsys):
    ok = cap._confirm_destination(_Resolution(),
                                  _args(confirm_destination="op:acct:WRONG:vault:X"))
    assert ok is False
    assert "does not match" in capsys.readouterr().err


def test_confirm_destination_match_allows():
    assert cap._confirm_destination(
        _Resolution(), _args(confirm_destination="op:acct:A1:vault:V1")) is True


def test_interactive_yes(monkeypatch):
    monkeypatch.setattr(cap.sys.stdin, "isatty", lambda: True)
    monkeypatch.setattr("builtins.input", lambda *_: "y")
    assert cap._confirm_destination(_Resolution(), _args()) is True


def test_interactive_no(monkeypatch):
    monkeypatch.setattr(cap.sys.stdin, "isatty", lambda: True)
    monkeypatch.setattr("builtins.input", lambda *_: "")
    assert cap._confirm_destination(_Resolution(), _args()) is False
