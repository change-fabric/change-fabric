# change-fabric platform infrastructure

Terraform for the hosted platform behind `changefabric.org`: the accounts,
organizations, contributor teams, and rehosted findings artifacts described in
the platform plan. This root is phase 1, the empty substrate. It provisions no
application code and no application-facing service, only the network, key,
database, secrets, and certificate every later phase builds on.

What it creates: one VPC (`10.40.0.0/16`) with two private subnets and no
internet path at all; three security groups (Lambda, RDS, VPC endpoint); an
interface VPC endpoint for SES SMTP; one CMK (`alias/cf-platform`); one shared
Postgres instance (`cf-platform`); four SSM SecureString parameters; and a
DNS-validated wildcard certificate for `*.staging.changefabric.org`.

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
originates traffic to the public internet: the one outbound dependency, SES
SMTP, is reached through an interface VPC endpoint instead. A NAT gateway would
add both a recurring cost and an internet egress path this design deliberately
avoids, so introducing one is a decision for a human, not a routine change.

The SES endpoint is single-AZ (`us-east-1a`) because an interface endpoint bills
per ENI per availability zone. That is a staging cost posture; phase 8 revisits
it alongside production.

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

- phase 2, the staging web app
- phase 3, the staging API
- phase 5, the staging artifacts host

Phase 1 provisions the parameter only. No consuming logic exists yet.

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

```
export AWS_PROFILE=personal
cd platform/infra
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
nothing else, and interface endpoints for `ssm`, `ssmmessages` and
`ec2messages`. Session Manager runs entirely over those endpoints, so the
bastion has no public IP and the VPC still has no internet path. It is created
for one run and destroyed straight after; the database and role live in RDS and
outlive it.

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

Confirm nothing is left behind. The only endpoint should be the SES one, and
there should be no instances at all:

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

## What this root does not own

- The `changefabric.org` hosted zone, and every record `site/infra` or
  `telemetry/infra` already manages. This root only reads the zone id and adds
  its own certificate validation records.
- The `cf-teams` DynamoDB table and everything else in `telemetry/infra`.
- Any Lambda, API Gateway, CloudFront distribution, or S3 bucket for the app,
  API, or artifacts. Those arrive in phases 2 through 5.
