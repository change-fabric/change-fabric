# change-fabric account infrastructure

The fourth Terraform root in this repository, and the only one that owns no
workload. `site/infra` runs the marketing site, `telemetry/infra` runs the
`api.changefabric.org` backend, `platform/infra` runs the staging platform. This
root runs the things that watch all three: alarms, an audit trail, cost
visibility, and two account-wide security controls.

It exists because a Well-Architected review of the live account
(`569032832755`, us-east-1) found that the estate had almost no operational
signal at all. A real, multi-service, live estate (a production marketing site, a
production API on four DynamoDB tables, a staging platform on a shared encrypted
Postgres instance) was running with **one CloudWatch alarm in the whole account,
and that one belonged to an unrelated workload**:

```
$ aws cloudwatch describe-alarms --query 'MetricAlarms[].AlarmName'
[ "pay-app-5xx" ]
```

The individual services are built carefully. Nothing was watching them.

## Why a separate root

Two reasons, and the second is the load-bearing one.

The first is ownership. A CloudWatch alarm on the RDS instance is not part of the
RDS instance. Putting cross-cutting observability into whichever root happens to
own the resource being watched means the site root grows a budget, the telemetry
root grows an SNS topic, and there are three notification paths to keep in step.

The second is that the other three roots were not safe to apply. At the time of
this review, a `terraform plan` in `platform/infra` from `main` reported
**`0 to add, 4 to change, 38 to destroy`**, because live state was ahead of `main`
by two changes still in flight (a Mailpit deployment and the staging apex in
PR #176). A plan in `site/infra` proposed reverting the tag-scoped OIDC trust
condition that PR #175 had already applied. Adding remediation to either root
would have meant either applying somebody else's half-finished work or reverting
it. This root has its own state file, creates only resources nothing else
manages, and references everything else by identifier, so it applies cleanly
regardless of what is in flight elsewhere. That drift is itself a finding, and it
is the first item under "Flagged, not fixed" below.

## What it creates

| File | Contents |
| --- | --- |
| `alerts.tf` | The `cf-alerts` SNS topic, its CMK, its topic policy, and the email subscription. Every alert in the account arrives through here. |
| `alarms.tf` | 25 CloudWatch alarms: four on the shared Postgres instance, `Errors` and `Throttles` on all seven Lambdas across the three roots, `5xx` on both HTTP APIs, `5xxErrorRate` on four CloudFront distributions, and one Route53 health check alarm on the production site. |
| `cloudtrail.tf` | A multi-region management-events trail with log file validation, its bucket, and a 365-day lifecycle. |
| `cost.tf` | Cost allocation tag activation, a tag-scoped monthly budget with ACTUAL and FORECASTED thresholds, and Cost Explorer anomaly detection. |
| `security.tf` | IAM Access Analyzer and an account password policy. Also documents the one control deliberately left out. |

## The one manual step

AWS mails a confirmation link when the SNS email subscription is created and the
subscription stays `PendingConfirmation` until it is clicked. Terraform reports
the subscription as created either way, so **a green apply is not proof that a
single alert can be delivered**. Confirm the mail, then check:

```
aws sns list-subscriptions-by-topic \
  --topic-arn arn:aws:sns:us-east-1:569032832755:cf-alerts \
  --profile personal --region us-east-1
```

A confirmed subscription shows a real subscription ARN in place of
`PendingConfirmation`.

## Cost this root adds

Roughly $2.50 a month, itemised so it is not a surprise:

- Route53 health check with the HTTPS option, about $1.50
- the `cf-alerts` CMK, $1.00
- CloudTrail S3 storage, cents at this account's management-event volume
- the 25 alarms, the budget, the anomaly monitor and Access Analyzer: free
  (CloudWatch's first ten alarms are free and standard-resolution alarms beyond
  that are $0.10 each, but these are all standard resolution and the account is
  well inside the free allotment for the metrics they read)

The first copy of management events in a region is free, which is why this trail
is management-only. Turning on data events would change the arithmetic by orders
of magnitude.

## Applying

```
cd account/infra
export AWS_PROFILE=personal
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Nothing here is destructive and nothing here is referenced by another root, so a
`terraform destroy` would remove the monitoring and leave every workload running.
That is the intended blast radius.

### Identifiers this root hardcodes

`variables.tf` carries literal CloudFront distribution ids, HTTP API ids, Lambda
function names and the RDS instance identifier. That is deliberate and the
reasoning is in the comment above `cloudfront_distributions`: there is no data
source that resolves a CloudFront distribution by alias, and a
`terraform_remote_state` read would couple this root's plan to another root's
state file, which is the coupling the separate-state decision exists to avoid. A
stale identifier fails visibly (the alarm sits in `INSUFFICIENT_DATA`) rather than
silently watching nothing.

If a distribution or API is ever replaced rather than updated, update the map
here in the same change.

## What the review found

Checked against live AWS state, not against the configuration alone. Where the
two disagreed, the disagreement is its own finding.

### Fixed by this root, applied and verified live

| Pillar | Finding | Evidence at the time |
| --- | --- | --- |
| Operational Excellence | No alarms on anything this repository owns | one alarm in the account, belonging to another project |
| Operational Excellence | No notification path at all; no root declares an SNS topic | an alarm would have had nowhere to send |
| Security | No CloudTrail in any region | `describe-trails` returned an empty `trailList` |
| Security | No IAM Access Analyzer | `list-analyzers` returned nothing |
| Security | No account password policy | `get-account-password-policy` returned `NoSuchEntity` |
| Reliability | Nothing watched the shared Postgres instance | no alarm on CPU, storage, memory or connections on a single-AZ `db.t4g.small` holding every environment |
| Reliability | No outside-in check on the production site | every metric in the account was AWS reporting on itself |
| Cost | The account budget has been in ALARM for years | $20 ceiling, July closed at $260.45, forecast $311.94, all four thresholds in `ALARM` |
| Cost | Every cost allocation tag was inactive | `Project`, `Root`, `ManagedBy`, `Env` all `Inactive`, so the platform root's tagging produced zero attribution |
| Cost | No anomaly detection | `get-anomaly-monitors` returned an empty list |

Two notes on the cost items. Cost allocation tag activation is **not
retroactive**, so `changefabric-monthly` has no history behind it and reads low
for its first month. And the pre-existing $20 console budget is deliberately left
alone: adopting a hand-built resource into Terraform in order to immediately
re-baseline it is a worse trade than leaving it. Recommendation is to delete it or
re-baseline it above the real run rate so it can alarm again.

### Flagged, not fixed

- **Terraform and live AWS disagree, in two roots, right now.** `platform/infra`
  planned from `main` reports `0 to add, 4 to change, 38 to destroy`, because live
  carries the Mailpit deployment and PR #176's staging apex. `site/infra` planned
  from `main` proposes reverting the tag-scoped OIDC trust condition PR #175 has
  already applied. `telemetry/infra` reports two `source_code_hash` changes: the
  deployed production Lambda code and the code in this repository are not the same
  bytes. The durable fixes are a plan-on-PR check in CI and state locking (no
  backend here sets `use_lockfile` or a lock table). Highest-value follow-on in
  this list.
- **A `c6i.2xlarge` tagged `aegis-aws-sandbox-one-day` has been running since
  2026-07-17.** Roughly $248 a month, essentially all of July's $136.95 EC2
  compute line and the reason for the $311 forecast. Not this repository's
  resource and stopping an instance is destructive, so it was not touched. Largest
  dollar value in the review, and one command to resolve if the sandbox is
  finished. It is also why anomaly detection is now in place: that control catches
  this class of accident generically.
- **Long-lived IAM access keys.** `patrick` and `synology` both carry static keys
  created in 2021 and never rotated. `synology` holds the managed
  `AmazonS3FullAccess`, which is `s3:*` on `*`, including the Terraform state
  bucket for all four roots. Scoping or rotating it would break a live backup job
  belonging to another project with no way to test the result from here.
  Recommended fix: replace the managed policy with an inline one naming the two
  `synology-*` bucket ARNs, then rotate. CloudTrail is now live, so which buckets
  that key actually touches is checkable before changing anything.
- **Six of seven VPC endpoint policies are `Action: *`, `Principal: *`,
  `Resource: *`.** The seventh, the S3 gateway endpoint, is properly narrowed
  (`platform/infra/endpoints.tf:76-85`). Not fixed because three of the six do not
  exist in `main` at all: `endpoints.tf` declares two, live has six, and
  `ecr.api`, `ecr.dkr` and `logs` came from the in-flight Mailpit work. Fix once
  that lands: narrow `ssm` to `parameter/cf-platform/*` and the rest to this
  account.
- **No account-level S3 public access block.** Every bucket this repository owns
  already blocks public access at the bucket level, verified individually, so
  there is no present exposure. `pstaylor-public`, belonging to another project,
  returns all four flags false with no bucket policy. Reasoning is in
  `security.tf`.
- **No dead-letter destination on any Lambda,** and the `cf-secret-scanner`
  stream trigger discards a record that fails four times. A DLQ without a consumer
  is a queue that fills up, so choosing the consumer is design work rather than
  remediation. The new `Errors` alarms mean a failure is at least noticed now.
- **No tested restore.** The shared instance has seven-day backups and deletion
  protection, both good, and no record of a restore ever having been performed.
  Proving it means restoring to a new identifier against a live shared database.

### Examined and deliberately left alone

- **No NAT gateway or internet gateway** was added, proposed or considered. The
  VPC's lack of both is a deliberate stance from earlier phases. Two findings
  above are downstream consequences of it and are written up as consequences, not
  as arguments against it.
- **The shared RDS instance was not split** per environment, and **the staging
  Basic Auth gate was not touched**. Both are documented decisions.
- **Telemetry Lambdas stay on `x86_64`** for now. Two of the five ship as ECR
  images because they link the native `ed25519` gem, so moving them is a build
  change rather than a Terraform one, and the other three are live production
  functions whose deployed code already differs from this repository. Changing
  architecture would ship an untested code change and an untested architecture
  change in one apply, to save a few dollars a year.
- **The six single-AZ interface endpoints** stay single-AZ. Roughly $44 a month
  and a single point of failure for the private path, with the cost reasoning
  stated in `endpoints.tf`. Correct for staging; the arithmetic flips when a
  production environment lands on the same VPC.

Nothing in this review destroyed or replaced anything. No RDS instance, no KMS
key, no VPC, no bucket, no credential rotated.
