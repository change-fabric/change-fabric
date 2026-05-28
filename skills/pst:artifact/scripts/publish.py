#!/usr/bin/env python3
"""Build the studio and publish artifacts to S3 + CloudFront.

Convention over configuration: reads <skill>/plans.config.json for the domain,
AWS profile, and region — then DERIVES everything else. The S3 bucket name
defaults to the domain, and the CloudFront distribution is discovered by its
alias (== domain), so there are no infra IDs in config. Shells out to the `aws`
CLI (same auth the rest of your tooling uses), so no extra Python deps.

  publish.py --skill-dir <path>                 # publish all artifacts
  publish.py --skill-dir <path> --id <id>       # publish, print that one's URL
  publish.py --skill-dir <path> --dry-run       # print the plan, do nothing

Exit codes: 0 ok · 2 config missing/invalid · 3 a shell step failed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

DEFAULT_TTL_DAYS = 7
NEVER = "never"

__all__ = ["Config", "load_config", "discover_distribution_id", "read_slug"]


class Config:
    """Resolved publish settings from plans.config.json."""

    def __init__(self, domain: str, profile: str, region: str, bucket: str) -> None:
        self.domain = domain
        self.profile = profile
        self.region = region
        self.bucket = bucket


def _fail(code: int, msg: str) -> "None":
    print(f"publish: {msg}", file=sys.stderr)
    raise SystemExit(code)


def load_config(skill_dir: Path) -> Config:
    cfg_path = skill_dir / "plans.config.json"
    if not cfg_path.is_file():
        _fail(
            2,
            "no plans.config.json — copy plans.config.example.json and fill in "
            "your domain + awsProfile to enable publishing.",
        )
    try:
        raw = json.loads(cfg_path.read_text())
    except json.JSONDecodeError as exc:
        _fail(2, f"plans.config.json is not valid JSON: {exc}")
    domain = str(raw.get("domain", "")).strip()
    profile = str(raw.get("awsProfile", "")).strip()
    region = str(raw.get("region", "us-east-1")).strip() or "us-east-1"
    if not domain or not profile:
        _fail(2, "plans.config.json needs both 'domain' and 'awsProfile'.")
    bucket = str(raw.get("bucket", "")).strip() or domain
    return Config(domain=domain, profile=profile, region=region, bucket=bucket)


def _aws(cfg: Config, *args: str) -> subprocess.CompletedProcess[str]:
    cmd = ["aws", *args, "--profile", cfg.profile, "--output", "json"]
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def discover_distribution_id(cfg: Config) -> Optional[str]:
    """Find the CloudFront distribution whose alias == the configured domain."""
    res = _aws(cfg, "cloudfront", "list-distributions")
    if res.returncode != 0:
        _fail(3, f"aws cloudfront list-distributions failed:\n{res.stderr.strip()}")
    try:
        data = json.loads(res.stdout or "{}")
    except json.JSONDecodeError:
        return None
    items = (data.get("DistributionList") or {}).get("Items") or []
    for dist in items:
        aliases = (dist.get("Aliases") or {}).get("Items") or []
        if cfg.domain in aliases:
            return str(dist.get("Id"))
    return None


def read_slug(plans_dir: Path, artifact_id: str) -> str:
    """Pull the cosmetic slug from an artifact's frontmatter (best effort)."""
    for ext in (".mdx", ".md"):
        path = plans_dir / f"{artifact_id}{ext}"
        if path.is_file():
            text = path.read_text()
            match = re.search(r"^permalink:\s*[\"']?([^\"'\n]+)", text, re.MULTILINE)
            if match:
                return match.group(1).strip()
    return artifact_id


def _run(
    cmd: list[str],
    cwd: Optional[Path] = None,
    env: Optional[dict[str, str]] = None,
) -> None:
    print(f"  $ {' '.join(cmd)}")
    res = subprocess.run(cmd, cwd=cwd, env=env, check=False)
    if res.returncode != 0:
        _fail(3, f"command failed ({res.returncode}): {' '.join(cmd)}")


def _build_env(studio: Path) -> dict[str, str]:
    """Env with the studio's node_modules/.bin prepended to PATH, so the build
    finds the local `astro` binary even when `npm run` doesn't augment PATH."""
    node_bin = studio / "node_modules" / ".bin"
    env = dict(os.environ)
    env["PATH"] = f"{node_bin}{os.pathsep}{env.get('PATH', '')}"
    return env


def parse_ttl(value: str) -> str:
    """Normalize a --ttl value to an expiry: an ISO-8601 UTC instant, or "never".
    Accepts a bare number of days, "<n>d", or never/forever/none/0."""
    v = value.strip().lower()
    if v in {NEVER, "none", "forever", "infinite", "inf", "0", ""}:
        return NEVER
    match = re.fullmatch(r"(\d+)\s*d?", v)
    if not match:
        _fail(2, f"--ttl must be a number of days or 'never' (got {value!r})")
    days = int(match.group(1))
    if days <= 0:
        return NEVER
    when = datetime.now(timezone.utc) + timedelta(days=days)
    return when.strftime("%Y-%m-%dT%H:%M:%SZ")


def existing_expiry(cfg: Config, artifact_id: str) -> Optional[str]:
    """Read the current `expires-at` tag of a published artifact, if any."""
    res = subprocess.run(
        [
            "aws", "s3api", "get-object-tagging",
            "--bucket", cfg.bucket, "--key", f"p/{artifact_id}/index.html",
            "--profile", cfg.profile, "--output", "json",
        ],
        capture_output=True, text=True, check=False,
    )
    if res.returncode != 0:
        return None
    try:
        tags = json.loads(res.stdout or "{}").get("TagSet", [])
    except json.JSONDecodeError:
        return None
    for tag in tags:
        if tag.get("Key") == "expires-at":
            return tag.get("Value")
    return None


def _cp(src: str, key: str, cfg: Config, *extra: str) -> None:
    _run([
        "aws", "s3", "cp", src, f"s3://{cfg.bucket}/{key}",
        "--profile", cfg.profile, *extra,
    ])


def _invalidate(cfg: Config, paths: list[str]) -> None:
    dist_id = discover_distribution_id(cfg)
    if dist_id is None:
        _fail(3, f"no CloudFront distribution with alias {cfg.domain}. terraform apply first.")
    _run([
        "aws", "cloudfront", "create-invalidation", "--distribution-id", dist_id,
        "--paths", *paths, "--profile", cfg.profile,
    ])


def destroy(cfg: Config, artifact_id: str) -> None:
    """Manually self-destruct one artifact now (the reaper does this on expiry)."""
    print(f"Destroying https://{cfg.domain}/p/{artifact_id} …")
    _run([
        "aws", "s3", "rm", f"s3://{cfg.bucket}/p/{artifact_id}/",
        "--recursive", "--profile", cfg.profile,
    ])
    _invalidate(cfg, [f"/p/{artifact_id}/*", "/", "/index.html"])
    print(f"Destroyed: /p/{artifact_id} is gone from S3.")


def run_a11y_gate(studio: Path) -> None:
    """Block publish on any WCAG AA contrast regression (src/a11y.test.ts)."""
    vitest = studio / "node_modules" / ".bin" / "vitest"
    if not vitest.exists():
        print("  (a11y gate skipped — vitest not installed)")
        return
    print("  $ a11y contrast gate")
    res = subprocess.run(
        [str(vitest), "run", "src/a11y.test.ts"], cwd=studio, check=False
    )
    if res.returncode != 0:
        _fail(3, "a11y contrast gate failed — fix theme/contrast before publishing.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skill-dir", required=True, type=Path)
    parser.add_argument("--id", help="artifact id (required to publish or destroy)")
    parser.add_argument(
        "--ttl",
        help="time-to-live: a number of days, or 'never'. Default: keep existing, "
        f"else {DEFAULT_TTL_DAYS} days. The skill normalizes fuzzy input.",
    )
    parser.add_argument(
        "--destroy", action="store_true", help="delete the --id artifact from S3 now"
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    skill_dir = args.skill_dir.resolve()
    studio = skill_dir / "studio"
    dist = studio / "dist"
    plans_dir = studio / "src" / "content" / "plans"
    cfg = load_config(skill_dir)

    if shutil.which("aws") is None:
        _fail(3, "the `aws` CLI is not on PATH.")

    if args.destroy:
        if not args.id:
            _fail(2, "--destroy needs --id")
        destroy(cfg, args.id)
        return 0

    if not args.id:
        _fail(2, "--id is required to publish (the artifact's short id).")

    # Resolve expiry: explicit --ttl wins; else keep the artifact's current
    # expiry; else the default window. Re-publishing thus never silently changes
    # an artifact's lifetime.
    if args.ttl is not None:
        expiry = parse_ttl(args.ttl)
    else:
        expiry = existing_expiry(cfg, args.id) or parse_ttl(str(DEFAULT_TTL_DAYS))

    slug = read_slug(plans_dir, args.id)
    url = f"https://{cfg.domain}/p/{args.id}/{slug}"
    src_mdx = next(
        (plans_dir / f"{args.id}{ext}" for ext in (".mdx", ".md")
         if (plans_dir / f"{args.id}{ext}").is_file()),
        None,
    )

    print(f"Publishing {args.id} → {url}")
    print(f"  expiry: {'never' if expiry == NEVER else expiry}")

    if args.dry_run:
        print("  [dry-run] a11y gate, build, upload artifact + source, tag, invalidate")
        print(f"\nWould publish: {url}")
        return 0

    run_a11y_gate(studio)

    astro_bin = studio / "node_modules" / ".bin" / "astro"
    if astro_bin.exists():
        _run([str(astro_bin), "build"], cwd=studio)
    else:
        _run(["npm", "run", "build"], cwd=studio, env=_build_env(studio))

    art_html = dist / "p" / args.id / "index.html"
    if not art_html.is_file():
        _fail(3, f"build produced no page for {args.id} at {art_html}")

    # Immutable shared assets (no per-object tags; never reaped).
    _run([
        "aws", "s3", "sync", str(dist / "_astro"), f"s3://{cfg.bucket}/_astro",
        "--profile", cfg.profile, "--size-only",
        "--cache-control", "public,max-age=31536000,immutable",
    ])
    # The artifact page (targeted cp so other artifacts' expiry tags are untouched).
    _cp(str(art_html), f"p/{args.id}/index.html", cfg,
        "--cache-control", "public,max-age=0,must-revalidate",
        "--content-type", "text/html; charset=utf-8")
    # Stash the MDX source privately so any future session can fetch + edit it.
    if src_mdx is not None:
        _cp(str(src_mdx), f"p/{args.id}/_source.mdx", cfg,
            "--content-type", "text/markdown")
    # Refresh the gallery + 404.
    _cp(str(dist / "index.html"), "index.html", cfg,
        "--cache-control", "public,max-age=0,must-revalidate",
        "--content-type", "text/html; charset=utf-8")
    if (dist / "404.html").is_file():
        _cp(str(dist / "404.html"), "404.html", cfg,
            "--content-type", "text/html; charset=utf-8")

    # Root static assets copied verbatim from public/ (favicons, robots.txt …).
    # These live at the bucket root, outside _astro/, so the targeted uploads
    # above miss them. A modest cache keeps icon swaps from lingering for a year.
    root_asset_keys: list[str] = []
    public_dir = studio / "public"
    if public_dir.is_dir():
        for asset in sorted(public_dir.iterdir()):
            shipped = dist / asset.name
            if asset.is_file() and shipped.is_file():
                _cp(str(shipped), asset.name, cfg,
                    "--cache-control", "public,max-age=86400")
                root_asset_keys.append(f"/{asset.name}")

    # Tag the page with its expiry — the reaper reads this to self-destruct it.
    _run([
        "aws", "s3api", "put-object-tagging", "--bucket", cfg.bucket,
        "--key", f"p/{args.id}/index.html", "--profile", cfg.profile,
        "--tagging", f"TagSet=[{{Key=expires-at,Value={expiry}}}]",
    ])

    _invalidate(cfg, [f"/p/{args.id}/*", "/", "/index.html", *root_asset_keys])

    print(f"\nPublished: {url}")
    if expiry == NEVER:
        print("Expiry: never (lives until you --destroy it).")
    else:
        print(f"Expiry: {expiry} — self-destructs after that (daily reaper).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
