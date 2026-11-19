# approval console infrastructure

Terraform for the remote approval console, deployed into your own AWS account,
us-east-1. One Lambda (ruby3.4, arm64) behind a function URL, one DynamoDB
table (`cf-approval-console`), a seed key and a receipt signing key (KMS), the
IAM roles, a log group, one error alarm, and a 5 USD monthly budget. The
function URL host is the WebAuthn rpId. The handler is `lambda/` (entry
`handler.rb`, routes in `console.rb`, DynamoDB in `store.rb`, KMS and DM in
`clients.rb`, pages in `pages.rb`); it shares `canonical`, `cbor`, `totp` and
`verifier` with the CLI, copied from `scripts/approval_console/` by `build.sh`.

## NEVER recreate the function or its URL

The URL host is the rpId. A new URL orphans every registered passkey, and
recovery is re-registering the passkey and re-running `enroll` on every
machine. `prevent_destroy` is set on both, so a plan that would replace either
fails. If it does, stop and read the plan.

## State backend

The shared bucket `changefabric-tfstate-569032832755`, key
`approval-console/terraform.tfstate`.

## Inputs with no default

`aws_profile` (your profile), `alert_email` (budget and alarm mail; confirm the
SNS subscription after the first apply), `claim_repos` (the consumer repos
whose `cf-prod.yml` may assume `cf-prod-claim`).

## Apply

`build.sh` stages the package in a linux/arm64 Lambda build container (Docker
and network needed; `CF_SKIP_GEMS=1` skips the gems for a plan-only dry run).

```
cd approval_console/infra
./build.sh
terraform init
terraform plan  -var aws_profile=... -var alert_email=... -var 'claim_repos=["owner@123/repo@456"]'
terraform apply -var aws_profile=... -var alert_email=... -var 'claim_repos=["owner@123/repo@456"]'
```

To ship a later change to the handler or the shared files (a new type or signed
field), the maintainer runs `redeploy.sh <merged sha>` from this directory's
checkout, through `~/.claude/cf/manual/queue/0006-approval-console-redeploy.sh`.
It refuses unless HEAD is that sha, the sha is an ancestor of `origin/main`, the
tree is clean and the AWS account is the expected one, and it never replaces the
function or its URL.

The agent never applies. The maintainer's script is
`~/.claude/cf/manual/queue/0005-approval-console-deploy.sh`. It needs a
`token.actions.githubusercontent.com` OIDC provider in the account (the site
root already relies on one) and 10 unreserved Lambda executions beyond the
reserved 5.

After apply, attach the `operator_policy_arn` output to the role or permission
set behind the profile that runs the CLI verbs (an account admin needs nothing).

Seed the DM parameters out of band (the handler skips the DM when missing):
`/cf/approval-console/dm-token` (SecureString) and
`/cf/approval-console/dm-recipient` (String).

## Routes

All under the function URL. Page GETs and registration are unauthenticated;
every other call needs the machine signature (`x-cf-timestamp`, `x-cf-signature`
over method, path, SHA-256 of the body and the timestamp) or a passkey
assertion plus TOTP.

| Route | Auth |
| --- | --- |
| `GET /register`, `POST /register/options`, `POST /register/verify` | one-time bootstrap token written by the CLI over IAM; a second credential also needs an assertion |
| `POST /m/<id>/requests` | machine signature; 20 per hour per machine |
| `GET /m/<id>/r/<request_id>` | none (page) |
| `POST /m/<id>/r/<request_id>/approve` | passkey assertion (UV) plus TOTP |
| `GET /m/<id>/r/<request_id>/proof` | machine signature |
| `POST /m/<id>/terminal-approve`, `POST /m/<id>/sync` | machine signature plus TOTP |
| `GET`/`POST /m/<id>/totp-enroll` | passkey assertion, once |

Rows the CLI writes over IAM (operator policy): `M#<id>/META` (`machine_key` PEM,
`label`, `version` 0), `M#<id>/SEED` (`ciphertext`, base64url KMS blob under the
`machine_id` context), `BOOT#<sha256 of token>/BOOT` (`machine_id`, `valid_until`
epoch, `expires_at` epoch). Pages carry a per-response nonce CSP with no
external script, and `Cache-Control: no-store`. Logs hold route and status only.

## Prod claim

`cf-prod-claim` is assumed by GitHub OIDC only, and only when `aud` is
`sts.amazonaws.com` and the token's `sub` matches
`repo:<o>@<oid>/<r>@<rid>:environment:<claim_environment>:job_workflow_ref:*`
for a repo in `claim_repos`. That is the customized immutable subject: each
consumer repo sets the template `include_claim_keys` [repo, context,
job_workflow_ref] so its credential roles can pin `cf-prod.yml` (the
generator prints the command). Only the trailing workflow is wildcarded. Each `claim_repos` entry is
the `sub_claim_prefix` that
`gh api repos/<o>/<r>/actions/oidc/customization/sub` reports, without `repo:`
(for example `octo@123/app@456`). `claim_environment` defaults to `cf-claim`, a
dedicated GitHub Environment with no required reviewers and a deployment branch
rule of the default branch only (create it in each consumer repo); that rule is
the branch pin. The claim role has no workflow-file pin: any default-branch workflow that
runs in the Environment can claim. The accepted worst case is a consumed
approval and a blocked prod run, which fails safe. Only `sub` and `aud` are used
because they are the documented IAM condition keys.

The role may `dynamodb:PutItem` on `CLAIM#*` keys only, with no read, update or
delete. The claim stops honest replays: the runner sends
`ConditionExpression attribute_not_exists(pk)`, but IAM cannot force it, so the
holder of the role could overwrite a claim and is already trusted. Item: `pk`
`CLAIM#<request_id>`, `sk` `CLAIM`, `digest`, `run_id`, `run_attempt`,
`claimed_at`, `expires_at` (epoch seconds, 30 days).

## Cost

Benign use, one user, a few dozen approvals a month. The URL is public, so
unauthenticated traffic can add Lambda and log cost up to the budget alert.

| Item | Monthly |
| --- | --- |
| KMS customer key (seeds) | 1.00 USD |
| KMS asymmetric key (receipts) | 1.00 USD |
| KMS requests (under 1k) | under 0.01 USD |
| Lambda (under 1k invocations) | 0 USD (free tier) or under 0.01 USD |
| DynamoDB on demand, under 1 MB | under 0.05 USD |
| CloudWatch logs and one alarm | about 0.10 to 0.20 USD |
| Total | about 2.20 to 2.30 USD |

## Shutdown and teardown

Stop traffic now: set `reserved_concurrency = 0` and apply (or
`aws lambda put-function-concurrency --function-name cf-approval-console
--reserved-concurrent-executions 0`). Teardown means lifting `prevent_destroy`
on purpose, and orphans every passkey.
