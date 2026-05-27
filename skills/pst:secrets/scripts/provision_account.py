#!/usr/bin/env python3
"""Provision (idempotently) the AWS resources the pst:secrets drawer needs in
an account: a customer-managed KMS key, an alias, and the MFA-enforcing key
policy that denies kms:Decrypt unless aws:MultiFactorAuthPresent is true.

Run once per account you want to use as a secret drawer, against a live
(MFA'd) session for that account's profile:

  PST_SECRETS_PROFILE=cas360 python3 provision_account.py --region us-east-1

Idempotent: re-running finds the existing alias/key and just re-asserts the key
policy. Prints the env-var block to use for that account afterward.

The MFA-deny statement is scoped to decrypt actions only - key-policy management
is never denied, so the account root can always revert it (no lockout).
"""
from __future__ import annotations

import argparse
import json
import sys

from aws_secrets import Config, SecretError, _account_of, _aws, ensure_session

POLICY_SID = "DenyDecryptWithoutMFA"


def _policy(account: str) -> str:
    return json.dumps({
        "Version": "2012-10-17",
        "Id": "key-default-1",
        "Statement": [
            {
                "Sid": "Enable IAM User Permissions",
                "Effect": "Allow",
                "Principal": {"AWS": f"arn:aws:iam::{account}:root"},
                "Action": "kms:*",
                "Resource": "*",
            },
            {
                "Sid": POLICY_SID,
                "Effect": "Deny",
                "Principal": "*",
                "Action": ["kms:Decrypt", "kms:ReEncryptFrom"],
                "Resource": "*",
                "Condition": {"BoolIfExists": {"aws:MultiFactorAuthPresent": "false"}},
            },
        ],
    })


def _alias_target(cfg: Config, alias: str) -> str | None:
    res = _aws(cfg, "kms", "list-aliases", "--output", "json")
    if res.returncode != 0:
        raise SecretError(f"list-aliases failed:\n{res.stderr.strip()}")
    for a in json.loads(res.stdout).get("Aliases", []):
        if a.get("AliasName") == alias:
            return a.get("TargetKeyId")
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description="Provision pst:secrets KMS resources for an account.")
    ap.add_argument("--profile")
    ap.add_argument("--region")
    ap.add_argument("--alias", default="alias/pst-secrets")
    ap.add_argument("--prefix", default="/pst-secrets")
    args = ap.parse_args()
    cfg = Config.from_env(profile=args.profile, region=args.region)

    try:
        account = _account_of(ensure_session(cfg))
        key_id = _alias_target(cfg, args.alias)
        if key_id:
            print(f"• alias {args.alias} already targets key {key_id} (reusing)")
        else:
            res = _aws(cfg, "kms", "create-key",
                       "--description", "pst:secrets -- SecureString encryption (MFA-gated)",
                       "--tags", "TagKey=project,TagValue=pst-secrets",
                       "--query", "KeyMetadata.KeyId", "--output", "text")
            if res.returncode != 0:
                raise SecretError(f"create-key failed:\n{res.stderr.strip()}")
            key_id = res.stdout.strip()
            res = _aws(cfg, "kms", "create-alias",
                       "--alias-name", args.alias, "--target-key-id", key_id)
            if res.returncode != 0:
                raise SecretError(f"create-alias failed:\n{res.stderr.strip()}")
            print(f"• created key {key_id} + alias {args.alias}")

        res = _aws(cfg, "kms", "put-key-policy", "--key-id", key_id,
                   "--policy-name", "default", "--policy", _policy(account))
        if res.returncode != 0:
            raise SecretError(f"put-key-policy failed:\n{res.stderr.strip()}")
        print(f"• MFA-deny key policy asserted on {key_id}")
    except SecretError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    print("\nReady. Use this env block for this account:")
    print(f"  PST_SECRETS_PROFILE={args.profile or cfg.profile or '<profile>'}")
    print(f"  PST_SECRETS_REGION={cfg.region}")
    print(f"  PST_SECRETS_KMS_KEY={args.alias}")
    print(f"  PST_SECRETS_PREFIX={args.prefix}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
