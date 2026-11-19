# approval console infrastructure

Terraform for the remote approval console, deployed into your own AWS account,
us-east-1. One Lambda (ruby3.4, arm64) behind a function URL, one DynamoDB
table (`cf-approval-console`), a seed key and a receipt signing key (KMS), the
IAM roles, a log group, one error alarm, and a 5 USD monthly budget. The
handler is a 503 placeholder until the console Lambda ships; the point of this
root is to create the function URL, whose host is the WebAuthn rpId.

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

```
cd approval_console/infra
./build.sh
terraform init
terraform plan  -var aws_profile=... -var alert_email=... -var 'claim_repos=["owner/repo"]'
terraform apply -var aws_profile=... -var alert_email=... -var 'claim_repos=["owner/repo"]'
```

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

## Prod claim

`cf-prod-claim` is assumed by GitHub OIDC only, and only when the token's `sub`
exactly equals
`repo:<o>/<r>:environment:<claim_environment>:job_workflow_ref:<o>/<r>/.github/workflows/cf-prod.yml@refs/heads/<claim_default_branch>`
for a repo in `claim_repos`. That needs the repo's custom subject template
(`include_claim_keys`: `repo`, `context`, `job_workflow_ref`, which the runner
generator prints). `claim_environment` defaults to `cf-claim`, a dedicated GitHub Environment with no required reviewers and a deployment branch rule of the default branch only (create it in each consumer repo); it must be non-empty. Matching the
whole subject pins repo, Environment, workflow file path and branch; only `sub`
and `aud` are used because they are the documented IAM condition keys.

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
