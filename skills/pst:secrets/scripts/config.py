#!/usr/bin/env python3
"""Catalog, project overlays, and destination resolution for pst:secrets.

Two layers of configuration:

* A **global catalog** (`~/.config/pst-secrets/config.json`, 0600) caches the
  1Password accounts and vaults discovered from the `op` CLI, plus human-chosen
  aliases / semantic labels, the AWS accounts, named drawer profiles, and the
  allowlist of `trusted_overlay_roots`.
* **Per-project overlays** (`.pst-secrets.json`, walked up from cwd, honoured
  only under a trusted root) set a preferred default destination for a workspace
  area. Overlays carry routing preferences, never secrets.

Resolution precedence for a write (`set`):  explicit flags / semantic override
-> trusted project overlay -> global default_profile -> guided catalog choice.
The result is a `Resolution` (a concrete backend + account + vault) which the
caller must *confirm* before the value is captured.

`op` is invoked through `_op`, the single subprocess seam, so discovery and
resolution are unit-testable by stubbing it.
"""
from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

CONFIG_PATH = Path(os.path.expanduser("~/.config/pst-secrets/config.json"))
CONFIG_VERSION = 1
OVERLAY_FILENAME = ".pst-secrets.json"

__all__ = [
    "CONFIG_PATH",
    "OVERLAY_FILENAME",
    "ConfigError",
    "OpVault",
    "OpAccount",
    "AwsAccount",
    "Profile",
    "Catalog",
    "Resolution",
    "load_catalog",
    "save_catalog",
    "discover_op",
    "refresh_catalog",
    "find_overlay",
    "resolve",
    "resolve_semantic",
]


class ConfigError(RuntimeError):
    """Raised for any catalog/overlay/resolution problem, with guidance."""


# ---------------------------------------------------------------- op seam

def _op(*args: str) -> subprocess.CompletedProcess[str]:
    """Run an `op` CLI command. The single subprocess seam (stub in tests)."""
    return subprocess.run(
        ["op", *args], capture_output=True, text=True, check=False
    )


def op_available() -> bool:
    try:
        return _op("--version").returncode == 0
    except FileNotFoundError:
        return False


# ---------------------------------------------------------------- dataclasses

@dataclass
class OpVault:
    id: str
    name: str
    alias: str = ""
    semantic_labels: list[str] = field(default_factory=list)
    missing_since: str | None = None

    @property
    def handle(self) -> str:
        return self.alias or self.name

    def to_dict(self) -> dict:
        d: dict = {"name": self.name, "alias": self.alias,
                   "semantic_labels": self.semantic_labels}
        if self.missing_since:
            d["missing_since"] = self.missing_since
        return d

    @classmethod
    def from_dict(cls, vault_id: str, d: dict) -> "OpVault":
        return cls(
            id=vault_id, name=d.get("name", ""), alias=d.get("alias", ""),
            semantic_labels=list(d.get("semantic_labels", [])),
            missing_since=d.get("missing_since"),
        )


@dataclass
class OpAccount:
    id: str
    alias: str = ""
    selector: str = ""
    display_name: str = ""
    url: str = ""
    last_seen: str | None = None
    missing_since: str | None = None
    vaults: dict[str, OpVault] = field(default_factory=dict)

    @property
    def handle(self) -> str:
        return self.alias or self.selector or self.id

    def to_dict(self) -> dict:
        d: dict = {
            "alias": self.alias, "selector": self.selector,
            "display_name": self.display_name, "url": self.url,
            "last_seen": self.last_seen,
            "vaults": {v.id: v.to_dict() for v in self.vaults.values()},
        }
        if self.missing_since:
            d["missing_since"] = self.missing_since
        return d

    @classmethod
    def from_dict(cls, account_id: str, d: dict) -> "OpAccount":
        return cls(
            id=account_id, alias=d.get("alias", ""), selector=d.get("selector", ""),
            display_name=d.get("display_name", ""), url=d.get("url", ""),
            last_seen=d.get("last_seen"), missing_since=d.get("missing_since"),
            vaults={vid: OpVault.from_dict(vid, vd)
                    for vid, vd in d.get("vaults", {}).items()},
        )


@dataclass
class AwsAccount:
    name: str
    aws_profile: str = ""
    region: str = "us-east-1"
    kms_key: str = "alias/pst-secrets"
    prefix: str = "/pst-secrets"

    def to_dict(self) -> dict:
        return {"aws_profile": self.aws_profile, "region": self.region,
                "kms_key": self.kms_key, "prefix": self.prefix}

    @classmethod
    def from_dict(cls, name: str, d: dict) -> "AwsAccount":
        return cls(name=name, aws_profile=d.get("aws_profile", ""),
                   region=d.get("region", "us-east-1"),
                   kms_key=d.get("kms_key", "alias/pst-secrets"),
                   prefix=d.get("prefix", "/pst-secrets"))


@dataclass
class Profile:
    name: str
    backend: str  # "op" | "aws-ssm"
    account: str = ""
    vault: str = ""

    def to_dict(self) -> dict:
        d: dict = {"backend": self.backend, "account": self.account}
        if self.backend == "op":
            d["vault"] = self.vault
        return d

    @classmethod
    def from_dict(cls, name: str, d: dict) -> "Profile":
        return cls(name=name, backend=d.get("backend", "op"),
                   account=d.get("account", ""), vault=d.get("vault", ""))


@dataclass
class Catalog:
    default_profile: str = ""
    op_accounts: dict[str, OpAccount] = field(default_factory=dict)
    aws_accounts: dict[str, AwsAccount] = field(default_factory=dict)
    profiles: dict[str, Profile] = field(default_factory=dict)
    trusted_overlay_roots: list[str] = field(default_factory=list)

    # -- lookups -------------------------------------------------------------

    def op_account_by_handle(self, handle: str) -> OpAccount | None:
        for acct in self.op_accounts.values():
            if handle in (acct.alias, acct.selector, acct.id, acct.url):
                return acct
        return None

    def aws_account_by_name(self, name: str) -> AwsAccount | None:
        return self.aws_accounts.get(name)

    def trusted_roots_resolved(self) -> list[Path]:
        return [Path(os.path.expanduser(r)).resolve() for r in self.trusted_overlay_roots]

    # -- serialization -------------------------------------------------------

    def to_dict(self) -> dict:
        return {
            "version": CONFIG_VERSION,
            "default_profile": self.default_profile,
            "op": {"accounts": {a.id: a.to_dict() for a in self.op_accounts.values()}},
            "aws": {"accounts": {a.name: a.to_dict() for a in self.aws_accounts.values()}},
            "profiles": {p.name: p.to_dict() for p in self.profiles.values()},
            "trusted_overlay_roots": self.trusted_overlay_roots,
        }

    @classmethod
    def from_dict(cls, d: dict) -> "Catalog":
        return cls(
            default_profile=d.get("default_profile", ""),
            op_accounts={aid: OpAccount.from_dict(aid, ad)
                         for aid, ad in d.get("op", {}).get("accounts", {}).items()},
            aws_accounts={name: AwsAccount.from_dict(name, ad)
                          for name, ad in d.get("aws", {}).get("accounts", {}).items()},
            profiles={name: Profile.from_dict(name, pd)
                      for name, pd in d.get("profiles", {}).items()},
            trusted_overlay_roots=list(d.get("trusted_overlay_roots", [])),
        )


# ---------------------------------------------------------------- Resolution

@dataclass
class Resolution:
    """A concrete, ready-to-confirm write destination."""
    backend: str  # "op" | "aws-ssm"
    source: str = ""  # where the choice came from (overlay path / "flag" / "default")
    # op
    op_account_id: str = ""
    op_account_selector: str = ""
    op_account_handle: str = ""
    op_vault_id: str = ""
    op_vault_name: str = ""
    op_vault_handle: str = ""
    # aws
    aws_account_name: str = ""
    aws_profile: str = ""
    aws_region: str = ""
    aws_kms_key: str = ""
    aws_prefix: str = ""

    @property
    def drawer_id(self) -> str:
        from registry import aws_drawer_id, op_drawer_id
        if self.backend == "op":
            return op_drawer_id(self.op_account_id, self.op_vault_id)
        return aws_drawer_id(self.aws_account_name, self.aws_region, self.aws_prefix)

    def describe(self) -> str:
        if self.backend == "op":
            acct = self.op_account_handle or self.op_account_selector or self.op_account_id
            vault = self.op_vault_name or self.op_vault_handle or self.op_vault_id
            base = f"op / {acct} / {vault}"
        else:
            base = (f"aws-ssm / {self.aws_account_name} "
                    f"({self.aws_region}, {self.aws_kms_key}, {self.aws_prefix})")
        return f"{base} [from {self.source}]" if self.source else base


# ---------------------------------------------------------------- load / save

def load_catalog() -> Catalog | None:
    if not CONFIG_PATH.exists():
        return None
    return Catalog.from_dict(json.loads(CONFIG_PATH.read_text()))


def save_catalog(catalog: Catalog) -> None:
    _validate_unique_aliases(catalog)
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(catalog.to_dict(), indent=2) + "\n")
    os.chmod(CONFIG_PATH, 0o600)


def _validate_unique_aliases(catalog: Catalog) -> None:
    acct_aliases: dict[str, str] = {}
    for acct in catalog.op_accounts.values():
        if not acct.alias:
            continue
        if acct.alias in acct_aliases:
            raise ConfigError(
                f"Account alias '{acct.alias}' is used by two accounts "
                f"({acct_aliases[acct.alias]} and {acct.id}). Aliases must be unique."
            )
        acct_aliases[acct.alias] = acct.id
        vault_aliases: dict[str, str] = {}
        for vault in acct.vaults.values():
            if not vault.alias:
                continue
            if vault.alias in vault_aliases:
                raise ConfigError(
                    f"Vault alias '{vault.alias}' is used twice in account "
                    f"'{acct.handle}'. Vault aliases must be unique within an account."
                )
            vault_aliases[vault.alias] = vault.id


# ---------------------------------------------------------------- discovery

def discover_op() -> list[OpAccount]:
    """Enumerate reachable 1Password accounts + their vaults via the op CLI.

    Returns accounts with freshly-discovered vaults but no aliases/labels --
    `refresh_catalog` merges those over any existing human-chosen metadata.
    """
    res = _op("account", "list", "--format=json")
    if res.returncode != 0:
        raise ConfigError(_op_auth_hint(res.stderr))
    raw = json.loads(res.stdout or "[]")
    if not raw:
        raise ConfigError(
            "`op account list` returned no accounts. Enable 1Password -> Settings "
            "-> Developer -> \"Integrate with 1Password CLI\", sign in, then retry."
        )
    accounts: list[OpAccount] = []
    for a in raw:
        account_id = a.get("account_uuid") or a.get("user_uuid") or a.get("url", "")
        selector = a.get("url", "") or account_id
        acct = OpAccount(
            id=account_id, selector=selector,
            display_name=a.get("email", "") or a.get("url", ""), url=a.get("url", ""),
            last_seen=None,
        )
        vres = _op("vault", "list", "--account", selector, "--format=json")
        if vres.returncode != 0:
            acct.missing_since = None  # reachable account, vault listing failed
            acct.vaults = {}
        else:
            for v in json.loads(vres.stdout or "[]"):
                vid = v.get("id", "")
                acct.vaults[vid] = OpVault(id=vid, name=v.get("name", ""))
        accounts.append(acct)
    return accounts


def _op_auth_hint(stderr: str) -> str:
    return (
        "1Password CLI is not ready: " + (stderr.strip() or "no accounts configured") +
        "\nFix: enable 1Password desktop app integration (Settings -> Developer -> "
        "\"Integrate with 1Password CLI\"), unlock the app, then re-run "
        "`/pst:secrets config --refresh`."
    )


def refresh_catalog(catalog: Catalog, discovered: list[OpAccount], when: str) -> Catalog:
    """Merge discovery into the catalog, preserving human metadata.

    Updates names + last_seen for known accounts/vaults, adds new ones, and marks
    entries no longer returned as `missing_since` rather than deleting them.
    """
    seen_accounts: set[str] = set()
    for disc in discovered:
        seen_accounts.add(disc.id)
        existing = catalog.op_accounts.get(disc.id)
        if existing is None:
            disc.last_seen = when
            catalog.op_accounts[disc.id] = disc
            continue
        existing.selector = disc.selector or existing.selector
        existing.display_name = disc.display_name or existing.display_name
        existing.url = disc.url or existing.url
        existing.last_seen = when
        existing.missing_since = None
        seen_vaults: set[str] = set()
        for vid, dv in disc.vaults.items():
            seen_vaults.add(vid)
            ev = existing.vaults.get(vid)
            if ev is None:
                existing.vaults[vid] = dv
            else:
                ev.name = dv.name or ev.name
                ev.missing_since = None
        for vid, ev in existing.vaults.items():
            if vid not in seen_vaults and ev.missing_since is None:
                ev.missing_since = when
    for aid, acct in catalog.op_accounts.items():
        if aid not in seen_accounts and acct.missing_since is None:
            acct.missing_since = when
    return catalog


# ---------------------------------------------------------------- overlays

def _under_trusted_root(path: Path, roots: list[Path]) -> bool:
    rp = path.resolve()
    for root in roots:
        try:
            rp.relative_to(root)
            return True
        except ValueError:
            continue
    return False


def find_overlay(start: Path, catalog: Catalog) -> tuple[Path, dict] | None:
    """Nearest `.pst-secrets.json` walking up from `start`, honoured only if it
    lives under a `trusted_overlay_roots` entry. Untrusted overlays are ignored.
    """
    roots = catalog.trusted_roots_resolved()
    if not roots:
        return None
    home = Path(os.path.expanduser("~")).resolve()
    current = start.resolve()
    while True:
        candidate = current / OVERLAY_FILENAME
        if candidate.is_file():
            if _under_trusted_root(candidate, roots):
                return candidate, json.loads(candidate.read_text())
            # found but untrusted: stop walking, do not silently use a higher one
            return None
        if current == home or current.parent == current:
            return None
        current = current.parent


# ---------------------------------------------------------------- resolution

@dataclass
class ResolveFlags:
    backend: str | None = None  # "op" | "aws-ssm"
    aws: bool = False
    profile: str | None = None
    account: str | None = None
    vault: str | None = None
    semantic: str | None = None


def _resolution_from_op(catalog: Catalog, acct: OpAccount, vault: OpVault,
                        source: str) -> Resolution:
    return Resolution(
        backend="op", source=source,
        op_account_id=acct.id, op_account_selector=acct.selector or acct.id,
        op_account_handle=acct.handle, op_vault_id=vault.id,
        op_vault_name=vault.name, op_vault_handle=vault.handle,
    )


def _resolution_from_aws(aws: AwsAccount, source: str) -> Resolution:
    return Resolution(
        backend="aws-ssm", source=source, aws_account_name=aws.name,
        aws_profile=aws.aws_profile, aws_region=aws.region,
        aws_kms_key=aws.kms_key, aws_prefix=aws.prefix,
    )


def _vault_in_account(acct: OpAccount, handle: str) -> OpVault:
    for vault in acct.vaults.values():
        if handle in (vault.alias, vault.name, vault.id):
            return vault
    matches = resolve_semantic_in_account(acct, handle)
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        names = ", ".join(v.handle for v in matches)
        raise ConfigError(f"'{handle}' is ambiguous in account '{acct.handle}': {names}. "
                          f"Use an exact vault alias or --vault.")
    raise ConfigError(f"No vault '{handle}' in account '{acct.handle}'. "
                      f"Known: {', '.join(v.handle for v in acct.vaults.values()) or '(none)'}.")


def _from_profile(catalog: Catalog, profile: Profile, source: str) -> Resolution:
    if profile.backend == "aws-ssm":
        aws = catalog.aws_account_by_name(profile.account)
        if aws is None:
            raise ConfigError(f"Profile '{profile.name}' references unknown AWS account "
                              f"'{profile.account}'. Run `/pst:secrets config`.")
        return _resolution_from_aws(aws, source)
    acct = catalog.op_account_by_handle(profile.account)
    if acct is None:
        raise ConfigError(f"Profile '{profile.name}' references unknown 1Password account "
                          f"'{profile.account}'. Run `/pst:secrets config --refresh`.")
    vault = _vault_in_account(acct, profile.vault)
    return _resolution_from_op(catalog, acct, vault, source)


def resolve(catalog: Catalog, overlay: dict | None, flags: ResolveFlags,
            overlay_source: str = "overlay") -> Resolution:
    """Resolve a write destination per precedence. Does NOT confirm -- the caller
    must confirm the returned Resolution before any value is captured."""
    # 1a. Semantic override (explicit natural-language destination).
    if flags.semantic:
        matches = resolve_semantic(catalog, flags.semantic)
        if len(matches) == 1:
            acct, vault = matches[0]
            return _resolution_from_op(catalog, acct, vault, "semantic override")
        if not matches:
            raise ConfigError(f"Could not match '{flags.semantic}' to any vault. "
                              + catalog_summary(catalog))
        rendered = "; ".join(f"{a.handle}/{v.handle}" for a, v in matches)
        raise ConfigError(f"'{flags.semantic}' matches multiple vaults: {rendered}. "
                          f"Disambiguate with --account/--vault.")

    # 1b. Explicit flags.
    if flags.aws or flags.backend == "aws-ssm":
        name = flags.account or _default_aws_name(catalog)
        aws = catalog.aws_account_by_name(name) if name else None
        if aws is None:
            raise ConfigError("No AWS account resolved. Pass --account <name> or add one "
                              "via `/pst:secrets config`.")
        return _resolution_from_aws(aws, "flag")
    if flags.profile:
        profile = catalog.profiles.get(flags.profile)
        if profile is None:
            raise ConfigError(f"Unknown profile '{flags.profile}'. Known: "
                              f"{', '.join(catalog.profiles) or '(none)'}.")
        return _from_profile(catalog, profile, f"profile {flags.profile}")
    if flags.account or flags.vault:
        acct = (catalog.op_account_by_handle(flags.account)
                if flags.account else _sole_op_account(catalog))
        if acct is None:
            raise ConfigError("Specify --account; could not infer a single 1Password account.")
        if not flags.vault:
            raise ConfigError(f"Account '{acct.handle}' selected; also pass --vault.")
        vault = _vault_in_account(acct, flags.vault)
        return _resolution_from_op(catalog, acct, vault, "flag")

    # 2. Trusted project overlay.
    if overlay:
        prof = _profile_from_overlay(catalog, overlay)
        return _from_profile(catalog, prof, overlay_source)

    # 3. Global default profile.
    if catalog.default_profile:
        profile = catalog.profiles.get(catalog.default_profile)
        if profile is None:
            raise ConfigError(f"default_profile '{catalog.default_profile}' is not defined "
                              f"in profiles. Run `/pst:secrets config`.")
        return _from_profile(catalog, profile, "default profile")

    # 4. No basis to choose -> caller must run guided setup.
    raise ConfigError("No destination could be resolved. Run `/pst:secrets config` to set "
                      "a default, or pass --profile/--account+--vault.")


def _profile_from_overlay(catalog: Catalog, overlay: dict) -> Profile:
    if overlay.get("profile") and overlay["profile"] in catalog.profiles:
        return catalog.profiles[overlay["profile"]]
    return Profile(
        name=overlay.get("profile", "overlay"),
        backend=overlay.get("backend", "op"),
        account=overlay.get("account", ""), vault=overlay.get("vault", ""),
    )


def _default_aws_name(catalog: Catalog) -> str:
    if catalog.default_profile:
        prof = catalog.profiles.get(catalog.default_profile)
        if prof and prof.backend == "aws-ssm":
            return prof.account
    return next(iter(catalog.aws_accounts), "")


def _sole_op_account(catalog: Catalog) -> OpAccount | None:
    live = [a for a in catalog.op_accounts.values() if a.missing_since is None]
    return live[0] if len(live) == 1 else None


# ---------------------------------------------------------------- semantic

# Filler words dropped before fuzzy semantic matching, so "the family shared
# vault" matches a "family shared" label. Kept tiny on purpose -- words like
# "my"/"private"/"shared" are meaningful and must NOT be stripped.
_STOPWORDS = frozenset({"the", "a", "an", "vault", "vaults", "please", "in", "to"})


def _content_words(text: str) -> list[str]:
    return [w for w in text.strip().lower().split() if w not in _STOPWORDS]


def resolve_semantic_in_account(acct: OpAccount, text: str) -> list[OpVault]:
    needle = text.strip().lower()
    exact = [v for v in acct.vaults.values()
             if needle == v.alias.lower() or needle == v.name.lower()
             or needle in [s.lower() for s in v.semantic_labels]]
    if exact:
        return exact
    words = _content_words(text)
    if not words:
        return []
    return [v for v in acct.vaults.values()
            if all(w in f"{v.name} {v.alias} {' '.join(v.semantic_labels)}".lower()
                   for w in words)]


def resolve_semantic(catalog: Catalog, text: str) -> list[tuple[OpAccount, OpVault]]:
    """Match a natural-language destination ("the family shared vault") to one or
    more (account, vault) candidates. Exact alias/label matches win over fuzzy."""
    needle = text.strip().lower()
    words = _content_words(text)
    exact: list[tuple[OpAccount, OpVault]] = []
    fuzzy: list[tuple[OpAccount, OpVault]] = []
    for acct in catalog.op_accounts.values():
        if acct.missing_since is not None:
            continue
        acct_tokens = [t for t in (acct.alias, acct.display_name, acct.url) if t]
        for vault in acct.vaults.values():
            labels = [vault.alias, vault.name, *vault.semantic_labels]
            label_blob = " ".join(t.lower() for t in labels if t)
            full_blob = (label_blob + " " + " ".join(t.lower() for t in acct_tokens)).strip()
            if needle == vault.alias.lower() or needle == vault.name.lower() \
                    or needle in [s.lower() for s in vault.semantic_labels]:
                exact.append((acct, vault))
            elif words and all(word in full_blob for word in words):
                fuzzy.append((acct, vault))
    return exact or fuzzy


def catalog_summary(catalog: Catalog) -> str:
    lines = ["Known destinations:"]
    for acct in catalog.op_accounts.values():
        tag = " (missing)" if acct.missing_since else ""
        vaults = ", ".join(v.handle for v in acct.vaults.values()) or "(no vaults)"
        lines.append(f"  op {acct.handle}{tag}: {vaults}")
    for aws in catalog.aws_accounts.values():
        lines.append(f"  aws {aws.name}: {aws.prefix}")
    return "\n".join(lines)
