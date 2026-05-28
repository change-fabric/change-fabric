#!/usr/bin/env python3
"""Generic browser secret-capture - the standard way to collect secrets locally.

Serves a small form on 127.0.0.1 (ephemeral port + random URL token), accepts
secret values via POST into masked fields, merges them into a chmod-600 env
file, then shuts itself down. Values post only to loopback and never touch
stdout or the conversation transcript.

Use this whenever a secret must be entered by hand (API keys, tokens, etc.):

  # Inline field spec - ENV[:Label[:hint]]
  secret_capture.py --out ~/.config/acme/secrets.env --title "Acme API" \
      --field ACME_API_KEY:"API Key":"from acme.com/settings" \
      --field ACME_ORG_ID:"Org ID"

  # JSON spec file: {title, subtitle, out, fields:[{env,label,hint}]}
  secret_capture.py --spec creds.json

  # Built-in preset
  secret_capture.py --preset unsplash

Behavior: merges into the target file (existing keys not in the form are kept),
writes 0600, prints the file path. Names are shown; values never are.
"""
from __future__ import annotations
import argparse, http.server, json, os, secrets, socket, subprocess, sys, threading, urllib.parse
from pathlib import Path

TOKEN = secrets.token_urlsafe(16)
_done = threading.Event()
_failed = threading.Event()

PRESETS = {
    "unsplash": {
        "title": "Unsplash credentials",
        "subtitle": "Unsplash API credentials.",
        "out": "~/.config/pst-secrets/secrets.env",
        "fields": [
            {"env": "UNSPLASH_APPLICATION_ID", "label": "Application ID", "hint": "e.g. 123456"},
            {"env": "UNSPLASH_ACCESS_KEY", "label": "Access Key", "hint": "used to look up photos"},
            {"env": "UNSPLASH_SECRET_KEY", "label": "Secret Key", "hint": "kept for completeness"},
        ],
    }
}

STYLE = """
  :root{--bg:#f7f5f1;--surface:#fffdfa;--ink:#23201b;--soft:#5c564d;--line:#e0dad0;
        --accent:#3f6f5f;--accent-ink:#274a3f;--accent-soft:#dce8e2}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--ink);min-height:100vh;display:grid;
       place-items:center;font:16px/1.6 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
  .card{background:var(--surface);border:1px solid var(--line);border-radius:14px;
        box-shadow:0 8px 28px rgba(40,34,28,.14);padding:30px 32px;width:min(460px,92vw)}
  .eyebrow{font-size:.72rem;letter-spacing:.14em;text-transform:uppercase;color:var(--accent);font-weight:600}
  h1{font-size:1.4rem;margin:.2em 0 .1em}
  p.sub{color:var(--soft);margin:0 0 18px;font-size:.92rem}
  label{display:block;font-size:.82rem;font-weight:600;color:var(--soft);margin:14px 0 4px}
  input{width:100%;padding:10px 12px;border:1px solid var(--line);border-radius:8px;font:inherit;background:var(--bg)}
  input:focus{outline:2px solid var(--accent-soft);border-color:var(--accent)}
  .hint{font-size:.74rem;color:#8a8378;margin-top:3px}
  .row{display:flex;align-items:center;gap:8px;justify-content:space-between}
  .reveal{font-size:.72rem;color:var(--accent);cursor:pointer;user-select:none;font-weight:600}
  button{margin-top:22px;width:100%;padding:12px;border:none;border-radius:999px;background:var(--accent);
         color:#fff;font:inherit;font-weight:600;cursor:pointer}
  button:hover{background:var(--accent-ink)}
  .ok{text-align:center}.ok .big{font-size:2.4rem}
  .note{font-size:.78rem;color:var(--soft);margin-top:14px;text-align:center}
  code{background:var(--accent-soft);color:var(--accent-ink);padding:2px 6px;border-radius:5px;font-size:.82em}
"""

REVEAL_JS = ("<script>function tg(b){var i=b.parentNode.nextElementSibling;"
             "if(i.type==='password'){i.type='text';b.textContent='hide'}"
             "else{i.type='password';b.textContent='show'}}</script>")


def esc(s: str) -> str:
    return (s or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def form_page(spec: dict, dest: str) -> str:
    rows = ""
    for f in spec["fields"]:
        env, lbl, hint = f["env"], f.get("label", f["env"]), f.get("hint", "")
        hint_html = f'<div class="hint">{esc(hint)} → <code>{esc(env)}</code></div>' if hint else \
                    f'<div class="hint"><code>{esc(env)}</code></div>'
        rows += (f'<div class="row"><label>{esc(lbl)}</label>'
                 f'<span class="reveal" onclick="tg(this)">show</span></div>'
                 f'<input type="password" name="{esc(env)}" autocomplete="off" spellcheck="false" '
                 f'placeholder="paste here">{hint_html}')
    sub = esc(spec.get("subtitle", ""))
    sub_html = f"{sub} " if sub else ""
    return (f"<!doctype html><html><head><meta charset=utf-8>"
            f"<title>{esc(spec['title'])}</title><style>{STYLE}</style></head><body>"
            f'<form class=card method=post action="/{TOKEN}">'
            f'<div class=eyebrow>secret capture</div><h1>{esc(spec["title"])}</h1>'
            f'<p class=sub>{sub_html}{esc(dest)} '
            f"Values post only to <code>127.0.0.1</code> and are never shown back.</p>"
            f"{rows}<button type=submit>Save securely &amp; close</button></form>{REVEAL_JS}</body></html>")


def done_page(dest: str) -> str:
    return (f"<!doctype html><html><head><meta charset=utf-8><title>Saved</title>"
            f"<style>{STYLE}</style></head><body><div class='card ok'>"
            f"<div class=big>✓</div><h1>Saved</h1>"
            f"<p class=sub>{esc(dest)}</p>"
            f"<p class=note>You can close this tab. The capture server has shut down.</p></div></body></html>")


def error_page(msg: str) -> str:
    return (f"<!doctype html><html><head><meta charset=utf-8><title>Failed</title>"
            f"<style>{STYLE}</style></head><body><div class='card ok'>"
            f"<div class=big>⚠</div><h1>Not saved</h1>"
            f"<p class=sub>{esc(msg)}</p>"
            f"<p class=note>Fix the issue and re-run. The capture server has shut down.</p></div></body></html>")


def merge_env(path: Path, updates: dict[str, str]) -> None:
    """Merge updates into an env file, preserving keys not present in this form."""
    existing: dict[str, str] = {}
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                existing[k.strip()] = v.strip()
    existing.update({k: f'"{v}"' for k, v in updates.items() if v})
    path.parent.mkdir(parents=True, exist_ok=True)
    body = "# secrets - chmod 600, do not commit\n" + \
           "\n".join(f"{k}={v}" for k, v in existing.items()) + "\n"
    path.write_text(body)
    os.chmod(path, 0o600)


def make_handler(spec: dict, out_path: Path, backend_obj, dest: str):
    """backend_obj is a SecretBackend (op / aws-ssm) or None for the file backend."""
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):  # stay quiet
            pass

        def _send(self, body: str, code: int = 200):
            b = body.encode()
            self.send_response(code)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)

        def do_GET(self):
            self._send(form_page(spec, dest) if self.path == f"/{TOKEN}" else "<h1>404</h1>",
                       200 if self.path == f"/{TOKEN}" else 404)

        def do_POST(self):
            if self.path != f"/{TOKEN}":
                self._send("<h1>404</h1>", 404); return
            n = int(self.headers.get("Content-Length", 0))
            data = urllib.parse.parse_qs(self.rfile.read(n).decode())
            updates = {f["env"]: data.get(f["env"], [""])[0].strip() for f in spec["fields"]}
            try:
                if backend_obj is not None:
                    labels = {f["env"]: f.get("label", f["env"]) for f in spec["fields"]}
                    for env, val in updates.items():
                        if val:
                            backend_obj.put(env, val, labels.get(env))
                else:
                    merge_env(out_path, updates)
            except Exception as exc:  # surface failure in-browser + on stderr
                self._send(error_page(str(exc)))
                print(f"Capture failed: {exc}", file=sys.stderr)
                _failed.set()
                _done.set()
                return
            self._send(done_page(dest))
            _done.set()
    return Handler


def parse_field(s: str) -> dict:
    # ENV[:Label[:hint]] - split on ':' but allow quoted segments
    import shlex
    parts, buf, depth = [], "", 0
    # simple split on unquoted ':'
    toks = []
    cur = ""
    quote = None
    for ch in s:
        if quote:
            if ch == quote:
                quote = None
            else:
                cur += ch
        elif ch in "\"'":
            quote = ch
        elif ch == ":":
            toks.append(cur); cur = ""
        else:
            cur += ch
    toks.append(cur)
    d = {"env": toks[0]}
    if len(toks) > 1 and toks[1]:
        d["label"] = toks[1]
    if len(toks) > 2 and toks[2]:
        d["hint"] = toks[2]
    return d


def build_spec(args) -> dict:
    if args.preset:
        if args.preset not in PRESETS:
            sys.exit(f"unknown preset '{args.preset}'; known: {', '.join(PRESETS)}")
        return PRESETS[args.preset]
    if args.spec:
        return json.loads(Path(args.spec).read_text())
    if not args.field:
        sys.exit("need --preset, --spec, or at least one --field")
    if args.backend == "file" and not args.out:
        sys.exit("--backend file needs --out <path>")
    return {
        "title": args.title or "Enter secrets",
        "subtitle": args.subtitle or "",
        "out": args.out or "(managed backend)",
        "fields": [parse_field(f) for f in args.field],
    }


def _resolve_destination(args):
    """Resolve a write destination from config + flags. Returns a config.Resolution.

    Raises config.ConfigError with guidance if no catalog exists or nothing
    resolves -- the agent should then run `/pst:secrets config` (guided setup).
    """
    import config as cfgmod
    catalog = cfgmod.load_catalog()
    if catalog is None:
        raise cfgmod.ConfigError(
            "No pst:secrets catalog yet. Run `/pst:secrets config` to set up your "
            "1Password accounts/vaults and a default destination."
        )
    overlay_pair = cfgmod.find_overlay(Path.cwd(), catalog)
    overlay = overlay_pair[1] if overlay_pair else None
    overlay_source = str(overlay_pair[0]) if overlay_pair else "overlay"
    flags = cfgmod.ResolveFlags(
        backend=args.backend if args.backend in ("op", "aws-ssm") else None,
        aws=args.aws, profile=args.profile, account=args.account,
        vault=args.vault, semantic=args.semantic,
    )
    return cfgmod.resolve(catalog, overlay, flags, overlay_source=overlay_source)


def _confirm_destination(resolution, args) -> bool:
    """Script-owned confirm-on-write. Non-interactive callers (the agent harness)
    must pass --confirm-destination matching the resolved drawer id; an
    interactive TTY is prompted. Returns True if confirmed."""
    if args.confirm_destination:
        if args.confirm_destination != resolution.drawer_id:
            print(f"Refusing to write: --confirm-destination "
                  f"'{args.confirm_destination}' does not match the resolved "
                  f"destination '{resolution.drawer_id}'.\nResolved: {resolution.describe()}",
                  file=sys.stderr)
            return False
        return True
    if sys.stdin.isatty():
        print(f"\nDestination: {resolution.describe()}")
        print(f"  drawer-id: {resolution.drawer_id}")
        reply = input("Write the secret here? [y/N] ").strip().lower()
        return reply in ("y", "yes")
    print("Refusing to write without confirmation. Re-run with "
          f"--confirm-destination {resolution.drawer_id}\nResolved: {resolution.describe()}",
          file=sys.stderr)
    return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--preset")
    ap.add_argument("--spec")
    ap.add_argument("--out")
    ap.add_argument("--title")
    ap.add_argument("--subtitle")
    ap.add_argument("--field", action="append", help="ENV[:Label[:hint]] (repeatable)")
    ap.add_argument("--backend", choices=("file", "op", "aws-ssm"), default=None,
                    help="override backend; default = resolved from config")
    ap.add_argument("--aws", action="store_true", help="use the AWS SSM backend")
    ap.add_argument("--profile", help="named drawer profile from the catalog")
    ap.add_argument("--account", help="op account handle / aws account name")
    ap.add_argument("--vault", help="op vault alias/name within the account")
    ap.add_argument("--semantic", help="natural-language destination, e.g. 'family shared vault'")
    ap.add_argument("--resolve-only", action="store_true",
                    help="print the resolved destination as JSON and exit (no write)")
    ap.add_argument("--confirm-destination",
                    help="drawer id that must match the resolved destination to allow the write")
    ap.add_argument("--out-legacy", dest="out", help=argparse.SUPPRESS)
    args = ap.parse_args()

    # Legacy plaintext file backend: bypass resolution entirely.
    if args.backend == "file":
        spec = build_spec(args)
        out_path = Path(os.path.expanduser(spec.get("out", "/dev/null")))
        dest = f"Saved to {spec['out']} (chmod 600)."
        return _serve(spec, out_path, None, dest, "file")

    from config import ConfigError
    try:
        resolution = _resolve_destination(args)
    except ConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    if args.resolve_only:
        print(json.dumps({
            "backend": resolution.backend,
            "drawer_id": resolution.drawer_id,
            "describe": resolution.describe(),
            "source": resolution.source,
        }))
        return 0

    spec = build_spec(args)
    if not _confirm_destination(resolution, args):
        return 3

    from backend import get_backend
    backend_obj = get_backend(resolution)
    try:  # fail fast before opening a browser if the session/unlock is dead
        backend_obj.ensure_session()
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 2
    dest = f"{resolution.describe()} - nothing is written to disk in plaintext -"
    return _serve(spec, Path("/dev/null"), backend_obj, dest, resolution.backend)


def _serve(spec: dict, out_path: Path, backend_obj, dest: str, backend_name: str) -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]; sock.close()
    httpd = http.server.HTTPServer(("127.0.0.1", port),
                                   make_handler(spec, out_path, backend_obj, dest))
    url = f"http://127.0.0.1:{port}/{TOKEN}"
    target = dest if backend_obj is not None else spec["out"]
    print(f"Secret-capture form (localhost only): {url}")
    print(f"Fields: {', '.join(f['env'] for f in spec['fields'])}  →  {target}")
    print("Fill it in your browser; this server shuts down once you save.")

    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    try:
        subprocess.run(["open" if sys.platform == "darwin" else "xdg-open", url], check=False)
    except FileNotFoundError:
        pass
    if not _done.wait(timeout=300):
        print("Timed out after 5 min; shutting down.", file=sys.stderr)
    httpd.shutdown()
    if _failed.is_set():
        print("No secrets saved (storage error above).", file=sys.stderr); return 1
    if backend_obj is not None:
        if _done.is_set():
            print(f"Stored to {backend_name}; local pointer registry updated.")
            return 0
        print("No secrets saved.", file=sys.stderr); return 1
    if out_path.exists():
        print(f"Saved {out_path} (chmod 600)."); return 0
    print("No secrets saved.", file=sys.stderr); return 1


if __name__ == "__main__":
    sys.exit(main())
