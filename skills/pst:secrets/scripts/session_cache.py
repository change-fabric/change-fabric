#!/usr/bin/env python3
"""Session-scoped secret materialization for the pst:secrets credential drawer.

An opt-in, time-boxed convenience layer. `session start` resolves a set of
already-registered secrets, fetches each value **once** (a single backend unlock
/ MFA prompt), and writes them to a private, ephemeral cache under ``$TMPDIR``.
For the life of the session, `get`/`export` read from this cache instead of the
backend, so an unattended agent keeps working without re-prompting for TouchID /
MFA -- the "stepped away from the machine" and "give the agent more autonomy for
one session" cases.

This DELIBERATELY trades the skill's "no plaintext on disk" guarantee for one
time-boxed session. The mitigations, in order of how much they actually buy:

  * **Short lifetime.** A TTL (default 12h, matching the /aws-mfa window) after
    which *any* access purges the cache, a detached watchdog shreds it at the
    deadline even if the session goes idle, and a Claude Code SessionEnd hook
    (`session install-hook`) shreds it on exit. `session end` shreds on demand.
  * **Private, ephemeral location.** The cache dir is ``0700`` and its files
    ``0600``, under ``$TMPDIR`` (per-user, not synced or backed up, OS-cleaned).

"Shred" is best-effort overwrite-then-unlink; on SSD/APFS physical erasure is
not guaranteed, so the real guarantee is the short lifetime + private location,
not the overwrite. Treat session mode as "lower the gate for a while," never as
"as safe as the backend."
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import secrets as _secrets
import signal
import subprocess
import sys
import time
from pathlib import Path

from backend import backend_from_drawer
from registry import all_drawers

__all__ = [
    "CACHE_VERSION",
    "DEFAULT_TTL_SECONDS",
    "session_dir",
    "cache_paths",
    "parse_duration",
    "load_session",
    "is_live",
    "lookup",
    "materialize",
    "warm",
    "purge",
    "status",
]

CACHE_VERSION = 1
DEFAULT_TTL_SECONDS = 12 * 3600  # 12h, mirrors the /aws-mfa session window

_UNITS = {"s": 1, "m": 60, "h": 3600, "d": 86400}


# ---------------------------------------------------------------- locations

def session_dir() -> Path:
    """Private, ephemeral cache dir. Overridable for tests via env."""
    override = os.environ.get("PST_SECRETS_SESSION_DIR")
    base = Path(override) if override else Path(_tmpdir()) / "pst-secrets"
    return base


def _tmpdir() -> str:
    return os.environ.get("TMPDIR") or "/tmp"


def cache_paths() -> tuple[Path, Path]:
    """(cache json -- canonical store with values, sourceable .env render)."""
    d = session_dir()
    return d / "session.json", d / "session.env"


def _ensure_dir() -> Path:
    d = session_dir()
    d.mkdir(parents=True, exist_ok=True)
    os.chmod(d, 0o700)
    return d


def _now() -> _dt.datetime:
    return _dt.datetime.now(_dt.timezone.utc)


def _parse_iso(value: str) -> _dt.datetime:
    dt = _dt.datetime.fromisoformat(value)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=_dt.timezone.utc)
    return dt


# ---------------------------------------------------------------- durations

def parse_duration(spec: str) -> int:
    """Parse a TTL spec into seconds.

    Accepts unit-suffixed forms (``30s``, ``45m``, ``12h``, ``1d``) and
    combinations (``1h30m``). A bare integer is interpreted as **minutes**
    (so ``90`` == ``90m``). Raises ``ValueError`` on anything else.
    """
    s = str(spec).strip().lower()
    if not s:
        raise ValueError("empty duration")
    if re.fullmatch(r"\d+", s):
        return int(s) * 60
    if not re.fullmatch(r"(\d+[smhd])+", s):
        raise ValueError(
            f"invalid duration {spec!r}; use forms like 12h, 45m, 1h30m, or a "
            "bare integer for minutes"
        )
    total = 0
    for num, unit in re.findall(r"(\d+)([smhd])", s):
        total += int(num) * _UNITS[unit]
    return total


def _humanize(seconds: int) -> str:
    seconds = max(0, int(seconds))
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h{m:02d}m"
    if m:
        return f"{m}m{s:02d}s"
    return f"{s}s"


# ---------------------------------------------------------------- shredding

def _secure_unlink(path: Path) -> None:
    """Best-effort overwrite-then-unlink. Never raises."""
    try:
        if not path.exists():
            return
        size = path.stat().st_size
        if size:
            with open(path, "r+b", buffering=0) as fh:
                fh.write(os.urandom(size))
                fh.flush()
                os.fsync(fh.fileno())
        os.remove(path)
    except OSError:
        pass


def _kill_watchdog(meta: dict) -> None:
    pid = meta.get("watchdog_pid")
    if not isinstance(pid, int):
        return
    try:
        os.kill(pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError, OSError):
        pass


# ---------------------------------------------------------------- read state

def _read_raw() -> dict | None:
    cache, _ = cache_paths()
    try:
        return json.loads(cache.read_text())
    except (OSError, ValueError):
        return None


def _is_expired(meta: dict) -> bool:
    try:
        return _now() > _parse_iso(meta["expires_at"])
    except (KeyError, ValueError):
        return True  # unparseable expiry -> treat as expired (fail closed)


def load_session() -> dict | None:
    """Return the live session metadata (incl. values), or None.

    Purges and returns None if the cache is missing, malformed, or expired.
    """
    meta = _read_raw()
    if meta is None:
        return None
    if _is_expired(meta):
        purge("expired", meta=meta, quiet=True)
        return None
    return meta


def is_live() -> bool:
    return load_session() is not None


def lookup(name: str) -> str | None:
    """Value for ``name`` if a session is live and holds it, else None."""
    meta = load_session()
    if meta is None:
        return None
    value = meta.get("values", {}).get(name)
    return value if isinstance(value, str) else None


def status() -> dict | None:
    """Session summary with **no values**, or None if nothing live."""
    meta = load_session()
    if meta is None:
        return None
    cache, env = cache_paths()
    remaining = (_parse_iso(meta["expires_at"]) - _now()).total_seconds()
    return {
        "cache": str(cache),
        "env": str(env),
        "created": meta.get("created"),
        "expires_at": meta.get("expires_at"),
        "expires_in": _humanize(remaining),
        "ttl_seconds": meta.get("ttl_seconds"),
        "names": sorted(meta.get("values", {}).keys()),
        "drawers": meta.get("drawers", {}),
        "origin": meta.get("origin", {}),
    }


# ---------------------------------------------------------------- write state

def _shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def _render_env(meta: dict) -> str:
    lines = [
        "# pst:secrets session cache -- ephemeral, plaintext, 0600.",
        f"# created {meta.get('created')}  expires {meta.get('expires_at')}",
        "# source this for autonomy; it is shredded on TTL / SessionEnd / `session end`.",
    ]
    for name in sorted(meta.get("values", {})):
        lines.append(f"export {name}={_shell_quote(meta['values'][name])}")
    return "\n".join(lines) + "\n"


def _write_private(path: Path, text: str) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, text.encode())
    finally:
        os.close(fd)
    os.chmod(path, 0o600)


def _persist(meta: dict) -> None:
    _ensure_dir()
    cache, env = cache_paths()
    _write_private(cache, json.dumps(meta, indent=2) + "\n")
    _write_private(env, _render_env(meta))


def _origin() -> dict:
    return {
        "pid": os.getpid(),
        "cwd": os.getcwd(),
        "session_id": os.environ.get("CLAUDE_SESSION_ID", ""),
    }


def materialize(values: dict[str, str], drawers: dict[str, str],
                ttl_seconds: int = DEFAULT_TTL_SECONDS) -> dict:
    """Write a fresh session cache holding ``values`` and spawn the watchdog.

    Replaces any existing session. Returns the persisted metadata.
    """
    now = _now()
    expires = now + _dt.timedelta(seconds=ttl_seconds)
    token = _secrets.token_hex(8)
    meta = {
        "version": CACHE_VERSION,
        "token": token,
        "created": now.isoformat(timespec="seconds"),
        "expires_at": expires.isoformat(timespec="seconds"),
        "ttl_seconds": int(ttl_seconds),
        "origin": _origin(),
        "drawers": dict(drawers),
        "values": dict(values),
        "watchdog_pid": None,
    }
    _persist(meta)
    pid = _spawn_watchdog(expires.timestamp(), token)
    if pid is not None:
        meta["watchdog_pid"] = pid
        _persist(meta)
    return meta


def warm(name: str, value: str, drawer_id: str | None = None) -> bool:
    """Add a backend-read value to a live session (warm-on-miss). No-op if dead."""
    meta = load_session()
    if meta is None:
        return False
    meta.setdefault("values", {})[name] = value
    if drawer_id:
        meta.setdefault("drawers", {})[name] = drawer_id
    _persist(meta)
    return True


def purge(reason: str = "manual", meta: dict | None = None, quiet: bool = False) -> bool:
    """Shred the session cache + .env and stop the watchdog. Idempotent."""
    if meta is None:
        meta = _read_raw()
    cache, env = cache_paths()
    existed = cache.exists() or env.exists()
    if meta:
        _kill_watchdog(meta)
    _secure_unlink(env)
    _secure_unlink(cache)
    try:
        d = session_dir()
        if d.exists() and not any(d.iterdir()):
            d.rmdir()
    except OSError:
        pass
    if existed and not quiet:
        print(f"Shredded pst:secrets session cache ({reason}).", file=sys.stderr)
    return existed


# ---------------------------------------------------------------- watchdog

def _spawn_watchdog(deadline_epoch: float, token: str) -> int | None:
    """Detached process that shreds the cache at the TTL deadline if untouched."""
    if os.environ.get("PST_SECRETS_NO_WATCHDOG"):
        return None
    try:
        proc = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "_watchdog",
             "--deadline", repr(deadline_epoch), "--token", token],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True,
        )
    except OSError:
        return None
    return proc.pid


def _run_watchdog(deadline_epoch: float, token: str) -> int:
    delay = deadline_epoch - time.time()
    if delay > 0:
        time.sleep(delay)
    meta = _read_raw()
    # Only shred if this is still *our* session (a re-materialize rotates token).
    if meta and meta.get("token") == token:
        purge("ttl-watchdog", meta=meta, quiet=True)
    return 0


# ---------------------------------------------------------------- hook install

def _hook_script() -> Path:
    return Path(__file__).resolve().parent / "session_end_hook.sh"


def install_hook() -> int:
    """Idempotently register the SessionEnd shred hook in ~/.claude/settings.json."""
    settings = Path("~/.claude/settings.json").expanduser()
    command = str(_hook_script())
    try:
        data = json.loads(settings.read_text()) if settings.exists() else {}
    except ValueError:
        print(f"error: {settings} is not valid JSON; fix it or add the hook "
              "manually.", file=sys.stderr)
        return 2
    hooks = data.setdefault("hooks", {})
    session_end = hooks.setdefault("SessionEnd", [])
    for group in session_end:
        for h in group.get("hooks", []):
            if h.get("command") == command:
                print(f"SessionEnd shred hook already installed in {settings}.")
                return 0
    session_end.append({"hooks": [{"type": "command", "command": command}]})
    settings.parent.mkdir(parents=True, exist_ok=True)
    settings.write_text(json.dumps(data, indent=2) + "\n")
    print(f"Installed SessionEnd shred hook in {settings}:\n  {command}")
    return 0


# ---------------------------------------------------------------- CLI

def _resolve_targets(names: list[str], use_all: bool,
                     scope: dict) -> list[tuple[str, object]]:
    targets: list[tuple[str, object]] = []
    if use_all:
        for _did, drawer in all_drawers().items():
            backend = backend_from_drawer(drawer)
            for name in drawer.get("secrets", {}):
                targets.append((name, backend))
        return targets
    import secret_fetch  # lazy: avoids an import cycle (secret_fetch imports us)
    for name in names:
        targets.append((name, secret_fetch.locate_backend(name, **scope)))
    return targets


def cmd_start(args: argparse.Namespace) -> int:
    scope = {"aws": args.aws, "account": args.account, "vault": args.vault}
    try:
        ttl = parse_duration(args.ttl)
        targets = _resolve_targets(args.names, args.all, scope)
    except (ValueError, RuntimeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    if not targets:
        print("error: nothing to materialize. Pass secret NAMEs or --all, and "
              "capture some first via /pst:secrets set \"<desc>\".", file=sys.stderr)
        return 2

    values: dict[str, str] = {}
    drawers: dict[str, str] = {}
    failures: list[str] = []
    for name, backend in targets:
        try:
            values[name] = backend.get(name)
            drawers[name] = backend.drawer_id
        except Exception as exc:  # backend OpError/SecretError carry guidance
            failures.append(f"{name}: {exc}")

    if not values:
        print("error: could not materialize any secret:\n  "
              + "\n  ".join(failures), file=sys.stderr)
        return 2

    meta = materialize(values, drawers, ttl)
    _, env = cache_paths()
    print(f"Materialized {len(values)} secret(s) for {_humanize(ttl)} "
          f"(expires {meta['expires_at']}).")
    print("Names: " + ", ".join(sorted(values)))
    print(f"Source for autonomy:  source {env}")
    print("get/export now read this cache (no unlock); use --fresh to force a "
          "backend read.")
    if failures:
        print("\nSkipped (left to the backend):\n  " + "\n  ".join(failures),
              file=sys.stderr)
    return 0


def cmd_status(_args: argparse.Namespace) -> int:
    info = status()
    if info is None:
        print("No live pst:secrets session. Start one with "
              "/pst:secrets session start <NAME...|--all>.")
        return 0
    print(f"Live session -- expires in {info['expires_in']} "
          f"(at {info['expires_at']}).")
    print(f"Cache: {info['cache']}")
    print(f"Env:   {info['env']}")
    if info["origin"].get("cwd"):
        print(f"Origin cwd: {info['origin']['cwd']}")
    print("Names (no values): " + (", ".join(info["names"]) or "(none)"))
    return 0


def cmd_end(args: argparse.Namespace) -> int:
    purge(args.reason, quiet=args.quiet)
    return 0


def cmd_path(_args: argparse.Namespace) -> int:
    if not is_live():
        print("error: no live session.", file=sys.stderr)
        return 2
    _, env = cache_paths()
    print(env)
    return 0


def cmd_install_hook(_args: argparse.Namespace) -> int:
    return install_hook()


def cmd_watchdog(args: argparse.Namespace) -> int:
    return _run_watchdog(float(args.deadline), args.token)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="pst:secrets session cache.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    start = sub.add_parser("start", help="materialize secrets for the session")
    start.add_argument("names", nargs="*", help="secret NAMEs to materialize")
    start.add_argument("--all", action="store_true", help="materialize every registered secret")
    start.add_argument("--ttl", default="12h", help="lifetime (e.g. 12h, 45m, 1h30m); default 12h")
    start.add_argument("--aws", action="store_true", help="scope NAMEs to the AWS backend")
    start.add_argument("--account", help="scope NAMEs to an op/aws account")
    start.add_argument("--vault", help="scope NAMEs to an op vault")
    start.set_defaults(func=cmd_start)

    st = sub.add_parser("status", help="show the live session (no values)")
    st.set_defaults(func=cmd_status)

    end = sub.add_parser("end", help="shred the session cache now")
    end.add_argument("--reason", default="manual")
    end.add_argument("--quiet", action="store_true")
    end.set_defaults(func=cmd_end)

    p = sub.add_parser("path", help="print the sourceable env file path")
    p.set_defaults(func=cmd_path)

    ih = sub.add_parser("install-hook", help="register the SessionEnd shred hook")
    ih.set_defaults(func=cmd_install_hook)

    wd = sub.add_parser("_watchdog", help=argparse.SUPPRESS)
    wd.add_argument("--deadline", required=True)
    wd.add_argument("--token", required=True)
    wd.set_defaults(func=cmd_watchdog)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
