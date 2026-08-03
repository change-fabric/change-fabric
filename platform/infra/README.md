# change-fabric platform infrastructure

Terraform for the hosted platform behind `changefabric.org`: the accounts,
organizations, contributor teams, and rehosted findings artifacts described in
the platform plan.

Phase 1 laid the substrate: one VPC (`10.40.0.0/16`) with two private subnets
and no internet path at all; three security groups (Lambda, RDS, VPC endpoint);
an interface VPC endpoint for SES SMTP; one CMK (`alias/cf-platform`); one
shared Postgres instance (`cf-platform`); four SSM SecureString parameters; and
a DNS-validated wildcard certificate for `*.staging.changefabric.org`.

Phase 2 puts the first service on it: the staging API from `platform/api`,
running as two Lambdas behind an HTTP API on `api.staging.changefabric.org`, and
the two extra interface endpoints those Lambdas need. See
[The staging API](#the-staging-api) below.

This is a separate root from `site/infra` and `telemetry/infra`. It shares the
state backend bucket and reads the `changefabric.org` hosted zone, but manages
neither, and it touches nothing either of those roots owns.

## State backend

Remote state lives in the **existing** bucket
`changefabric-tfstate-569032832755` (the one `site/infra` bootstrapped) under a
new key, `changefabric-platform/terraform.tfstate`. There is nothing new to
bootstrap: the bucket is reused as-is. If it somehow does not exist yet, create
it once as in `site/infra/README.md`.

Later phases read this root's outputs rather than duplicating any of it:

```hcl
data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket = "changefabric-tfstate-569032832755"
    key    = "changefabric-platform/terraform.tfstate"
    region = "us-east-1"
  }
}
```

## One instance, many databases

`cf-platform` is a single Postgres instance shared by every environment, split by
**database**, not by instance. Staging is `cf_platform_staging`; phase 8 adds
`cf_platform_production` to the same instance, alongside it in `postgres.tf`,
using the same `postgresql_database` plus `postgresql_role` plus
`postgresql_grant` trio. Nothing in this phase needs to change for that to
happen.

Both databases share one login role each, created through the bootstrap
procedure below. The staging pair exists today; phase 8 adds the production pair
the same way.

This is a settled decision. A second instance would double the baseline spend,
the backup surface, and the patching work for two workloads that together stay
well inside one `db.t4g.small`, which is why the class was chosen with headroom
for both from day one rather than sized to staging alone. The instance
identifier is deliberately environment-neutral: only the database, the role, and
DNS names carry an environment suffix.

The instance carries `deletion_protection = true` and
`skip_final_snapshot = false`, so it cannot be deleted without deliberately
clearing both.

## No internet path, and why there is no NAT gateway

The VPC has no internet gateway and no NAT gateway. Nothing in the platform
originates traffic to the public internet: every outbound dependency is reached
through an interface VPC endpoint instead. A NAT gateway would add both a
recurring cost and an internet egress path this design deliberately avoids, so
introducing one is a decision for a human, not a routine change.

There are three standing endpoints, all single-AZ (`us-east-1a`) because an
interface endpoint bills per ENI per availability zone. That is a staging cost
posture; phase 8 revisits it alongside production. Cross-AZ traffic inside the
VPC reaches them from either subnet, so a Lambda ENI in `us-east-1b` is fine.

| Endpoint | Added by | Why |
| --- | --- | --- |
| `email-smtp` | phase 1 | SMTP submission to SES. |
| `email` | phase 2 | The SES **v2 API**, on `email.us-east-1.amazonaws.com`. This is a different service from SMTP submission, and the phase 1 endpoint does not carry `SendEmail` calls. Without it the SDK call hangs until its own timeout. |
| `ssm` | phase 2 | The API Lambda reads its secrets from SSM at cold start, and nothing in this VPC can reach a public API. |

The `ssm` endpoint is deliberately a standing one rather than part of the
bastion's set, because AWS refuses a second endpoint for the same service with
private DNS in one VPC. `bastion.tf` therefore creates only `ssmmessages` and
`ec2messages`, and reaches the standing `ssm` endpoint through two gated rules
in `endpoints.tf` that come and go with the bastion.

## Secrets

Four SSM SecureString parameters. None of their values is a Terraform output,
and none is printed by a plan or an apply.

| Parameter | Purpose |
| --- | --- |
| `/cf-platform/db-master-password` | Master user password for the `cf-platform` instance. Used only to administer the instance and create per-environment databases and roles. Application code never reads it. |
| `/cf-platform/staging/db-password` | Password for the `cf_platform_staging_app` login role. This is what the staging API connects with from phase 2 onward. |
| `/cf-platform/staging/better-auth-secret` | Better Auth session signing secret for staging. Provisioned now because it is pure infrastructure; phase 2 is the first consumer. |
| `/cf-platform/staging/basic-auth-credential` | Shared HTTP Basic Auth credential gating every staging surface. See below. |

### Staging HTTP Basic Auth, a note for phases 2, 3 and 5

`/cf-platform/staging/basic-auth-credential` holds a `user:pass` pair, colon
separated. It backs a staging-wide HTTP Basic Auth gate that sits **in front of**
the platform's real per-organization authentication, not instead of it: it keeps
the whole staging environment off the open internet while the product's own auth
is being built.

Every staging-facing surface applies it, and all of them read this one parameter
so the credential stays in a single place:

- phase 2, the staging API (done)
- phase 3, the staging web app
- phase 5, the staging artifacts host

The API reads it once at cold start, caches it in module scope, and compares
with a constant-time comparison. Everything except `/healthz` sits behind it;
`/healthz` is exempt so the Lambda and gateway wiring can be confirmed before
SSM or the database is reachable.

### Bootstrapping the parameters by hand

This root generates all three random values in-config with the `random`
provider, so the first apply needed no out-of-band step and no human ever
handled a secret. The values reach exactly two places: the encrypted remote
state, and SSM.

If a future re-provision should instead seed them out of band (for instance to
carry an existing value forward), create each parameter before applying and
replace the corresponding `aws_ssm_parameter` resource with a
`data "aws_ssm_parameter"` read:

```
export AWS_PROFILE=personal

aws ssm put-parameter --region us-east-1 \
  --name /cf-platform/db-master-password \
  --type SecureString --value "$(openssl rand -base64 32)"

aws ssm put-parameter --region us-east-1 \
  --name /cf-platform/staging/db-password \
  --type SecureString --value "$(openssl rand -base64 32)"

aws ssm put-parameter --region us-east-1 \
  --name /cf-platform/staging/better-auth-secret \
  --type SecureString --value "$(openssl rand -base64 32)"

aws ssm put-parameter --region us-east-1 \
  --name /cf-platform/staging/basic-auth-credential \
  --type SecureString --value 'changefabric:changefabric'
```

Rotating a value in place is a `put-parameter --overwrite` plus a re-apply of
whichever phase consumes it. The RDS master password is pinned with
`ignore_changes`, so rotating it is a deliberate `modify-db-instance`, never a
side effect of a plan.

## Provision

The Lambda deployment package is zipped from `platform/api/dist`, so that has to
exist before a plan. Build it first, every time:

```
export AWS_PROFILE=personal

cd platform/api
npm ci
npm run build

cd ../infra
terraform init
terraform plan
terraform apply
```

The apply creates the certificate and waits for DNS validation, writing the
validation records into the existing zone in the same run. Validation usually
completes in a few minutes. The RDS instance takes several minutes more to reach
`available`.

Verify:

```
aws rds describe-db-instances --profile personal --region us-east-1 \
  --db-instance-identifier cf-platform \
  --query 'DBInstances[0].DBInstanceStatus'

aws acm describe-certificate --profile personal --region us-east-1 \
  --certificate-arn "$(terraform output -raw acm_certificate_arn)" \
  --query 'Certificate.Status'
```

## Creating a Postgres database and role: the bootstrap procedure

`postgres.tf` declares `cf_platform_staging`, the `cf_platform_staging_app`
login role, and its grants. They already exist; `manage_postgres_objects`
defaults to **true** so a plan matches reality.

Getting them created took a detour, and phase 8 will take the same one to add
`cf_platform_production`. The `postgresql` provider speaks Postgres over TCP
5432 from wherever Terraform runs, and this instance is private on purpose: no
internet gateway, no NAT, `publicly_accessible = false`. A laptop cannot reach
it. Making the instance publicly reachable is not an alternative either, because
RDS requires an internet gateway in the VPC before it accepts
`publicly_accessible = true`, and this VPC has none by design.

`bastion.tf` closes the gap for exactly as long as it takes. It is gated on
`provision_bastion` (default **false**), and it stands up one `t4g.nano` in a
private subnet, an instance profile holding `AmazonSSMManagedInstanceCore` and
nothing else, and interface endpoints for `ssmmessages` and `ec2messages`. It
reaches the standing `ssm` endpoint from `endpoints.tf` through two rules gated
on the same variable. Session Manager runs entirely over those three endpoints,
so the bastion has no public IP and the VPC still has no internet path. It is
created for one run and destroyed straight after; the database and role live in
RDS and outlive it.

This is only for Postgres **catalog** objects, the database and the login role.
Application schema migrations do not use it: they run inside the VPC through the
`cf-platform-migrate` Lambda, below.

### 1. Stand the bastion up

```
export AWS_PROFILE=personal
terraform apply -var provision_bastion=true
```

Wait for the agent to register, which takes a minute or two:

```
aws ssm describe-instance-information --region us-east-1 \
  --filters "Key=InstanceIds,Values=$(terraform output -raw bastion_instance_id)" \
  --query 'InstanceInformationList[0].PingStatus'
```

If it never leaves `None`, check that the role actually carries
`AmazonSSMManagedInstanceCore`. Terraform has no ordering edge between the
policy attachment and the instance, so an instance that boots first gets no
credentials and the agent backs off for a long time. Attaching the policy and
rebooting the instance clears it.

### 2. Open a port-forward to the instance

Needs the `session-manager-plugin` alongside the AWS CLI.

```
aws ssm start-session --region us-east-1 \
  --target "$(terraform output -raw bastion_instance_id)" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$(terraform output -raw rds_address)\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"55432\"]}"
```

### 3. Apply the Postgres objects through the tunnel

In another shell, with the session still open:

```
terraform apply -var provision_bastion=true \
  -var postgresql_host=localhost -var postgresql_port=55432
```

### 4. Tear the bastion down

Because a saved plan does not refresh, build the plan while the tunnel is still
up, then close it and apply. Otherwise the teardown run tries to reach Postgres
that is no longer reachable and fails partway.

```
terraform plan -var provision_bastion=false \
  -var postgresql_host=localhost -var postgresql_port=55432 \
  -out=tfplan.teardown

# close the session, then:
terraform apply tfplan.teardown
```

Confirm nothing is left behind. The only endpoints should be the three standing
ones (`email-smtp`, `email`, `ssm`), and there should be no instances at all:

```
aws ec2 describe-instances --region us-east-1 \
  --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId'

aws ec2 describe-vpc-endpoints --region us-east-1 \
  --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)" \
  --query 'VpcEndpoints[].ServiceName'
```

### Planning this root after the fact

With the bastion gone there is no path to Postgres, so a plain `terraform plan`
fails on the provider connection. That is deliberate. The alternative, defaulting
`manage_postgres_objects` to false, would make a plain plan quietly propose
**dropping the staging database**, so this fails closed instead. `postgres.tf`
also carries `prevent_destroy` on the database as a second guard.

To plan or apply this root normally, repeat steps 1 through 4 around whatever
change you are making. Later phases are unaffected: they have their own roots and
read this one through `terraform_remote_state`, never by planning it.

## The staging API

`lambda.tf` and `apigateway.tf` run the code in `platform/api` as two functions
off one bundle:

| Function | Handler | Shape | Reached by |
| --- | --- | --- | --- |
| `cf-platform-api` | `index.handler` | 512 MB, 15s, reserved concurrency 10 | API Gateway, on `api.staging.changefabric.org` |
| `cf-platform-migrate` | `migrate.handler` | 1024 MB, 300s | direct invoke only, no route |

Both sit in the two private subnets on the phase 1 Lambda security group, and
share one role whose policy names the four SSM parameters individually rather
than granting `/cf-platform/*`.

`api.staging.changefabric.org` is a regional custom domain on phase 1's wildcard
certificate, aliased into the existing zone. It is the only record this root
adds beyond certificate validation.

### The maintenance function

The database has no path from outside the VPC, so anything that needs to talk to
it has to run inside. `cf-platform-migrate` is that place. It takes three
actions:

```
# apply every pending migration, as the RDS master user
aws lambda invoke --profile personal --region us-east-1 \
  --function-name cf-platform-migrate \
  --cli-binary-format raw-in-base64-out \
  --payload '{"action":"migrate"}' /dev/stdout

# read a row back, as the application role, in a READ ONLY transaction
aws lambda invoke --profile personal --region us-east-1 \
  --function-name cf-platform-migrate \
  --cli-binary-format raw-in-base64-out \
  --payload '{"action":"query","sql":"select count(*) from \"user\""}' /dev/stdout

# prove the SES path out of the VPC, using the mailbox simulator
aws lambda invoke --profile personal --region us-east-1 \
  --function-name cf-platform-migrate \
  --cli-binary-format raw-in-base64-out \
  --payload '{"action":"sesCheck","from":"<a verified identity>","to":"success@simulator.amazonses.com"}' /dev/stdout
```

Migrations run as the master user because the application role holds no DDL
privilege by design. Migration `0001` grants that role the table privileges it
needs, plus default privileges so later migrations do not have to remember.

The `query` action opens a `READ ONLY` transaction and always rolls back, so
Postgres itself rejects a write regardless of what statement arrives.

### Transactional mail, and what is still missing

The API sends Better Auth's verification mail through the SES v2 API. The path
works: IAM, the SDK, and the `email` interface endpoint are all in place, and a
send to `success@simulator.amazonses.com` succeeds from inside the VPC.

What does not work yet is sending **as** `no-reply@staging.changefabric.org`.
SES rejects it because `changefabric.org` is not a verified SES identity in this
account, and verifying a domain means publishing three DKIM CNAMEs in the zone.
That is a deliberate gap: this phase adds exactly one DNS record. A send failure
is logged and swallowed rather than failing the sign-up it belongs to, so the
account is created either way.

Two things unblock real delivery, in this order:

1. Verify `changefabric.org` (or `staging.changefabric.org`) as an SES domain
   identity, which adds the DKIM records to the zone.
2. Leave the SES sandbox, which is a support request. Until then SES only
   delivers to verified recipients and to the mailbox simulator.

`var.ses_from_address` overrides the sender if a different verified identity
should be used in the meantime.

## What this root does not own

- The `changefabric.org` hosted zone, and every record `site/infra` or
  `telemetry/infra` already manages. This root only reads the zone id, adds its
  own certificate validation records, and adds the one alias record for
  `api.staging.changefabric.org`.
- The `cf-teams` DynamoDB table and everything else in `telemetry/infra`.
- Any CloudFront distribution or S3 bucket for the web app or the artifacts
  host. Those arrive in phases 3 and 5.
