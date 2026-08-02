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

Phase 3 adds the staging web app from `platform/web`: a private S3 bucket behind
a CloudFront distribution on `app.staging.changefabric.org`, gated by a
viewer-request CloudFront Function, and a GitHub OIDC deploy role for a future CI
workflow. See [The staging web app](#the-staging-web-app) below.

Phase 5 adds the staging artifacts host: a private S3 bucket of published
findings runs behind a CloudFront distribution on
`artifacts.staging.changefabric.org`, gated by the same staging Basic Auth and by
CloudFront signed cookies the API mints. See [The staging artifacts
host](#the-staging-artifacts-host) below.

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

## The staging web app

`webapp.tf` serves `platform/web` from `app.staging.changefabric.org`: a private
S3 bucket (`changefabric-platform-app-staging`, public access fully blocked, read
only by CloudFront through an origin access control), a CloudFront distribution
on phase 1's wildcard certificate, one alias record, and a GitHub OIDC deploy role
modelled on `site/infra/oidc.tf`.

Client-side routing is done in the viewer-request function, not with a
`custom_error_response`. See "The distribution also fronts the API" below for why
that distinction matters here and nowhere else in this estate.

Structurally this is `site/infra/main.tf`. Two differences carry the design.

### The distribution also fronts the API

There is a second origin, the phase 2 API Gateway custom domain, behind `/api/*`
and `/v1/*` with caching disabled and every method allowed. The web app is
therefore **same-origin with its own API**, which is what makes it work behind
the shared Basic Auth gate at all: a browser replays Basic credentials only to
the origin that challenged it, so a direct cross-origin call from the app host to
`api.staging` arrives with no `Authorization` header and the API's own gate
rejects it. The alternative is shipping the staging credential in the JavaScript
bundle. Same-origin also removes the CORS preflight, which the API cannot answer
in any case: preflights carry no credentials, and the router registers `GET` and
`POST` only. `platform/web/README.md` has the longer version.

`api.staging.changefabric.org` is unchanged and still reachable directly. This
adds a second path to the same Lambda, it does not replace the first.

It also rules out the usual SPA fallback. Mapping 403 and 404 to `/index.html`
with a 200 is how a static site on S3 behind OAC normally does client-side
routing, and phase 3 did exactly that. A `custom_error_response` is
**distribution-wide**, though, and this distribution also fronts the API, so once
phase 4 added routes that legitimately answer 403 (a member attempting an
owner-only write) and 404 (an id belonging to another organization), every one of
those reached the browser as a 200 carrying an HTML page. The app could only
report that the body was unreadable, never the reason the API gave.

The routing therefore moved into the viewer-request function, which rewrites an
extensionless path that is not `/api/*` or `/v1/*` to `/index.html`. That is
scoped by construction: an API path is returned untouched, so its status arrives
at the caller intact. There is no `custom_error_response` on this distribution
and there should not be one.

### The Basic Auth gate is a digest, and Terraform does not own it

A CloudFront Function has no network access, so unlike the API's Lambda
middleware it cannot read SSM per request. `platform/web/basic-auth.function.js`
is a template; `platform/web/deploy.sh` reads
`/cf-platform/staging/basic-auth-credential`, compiles in only the SHA-256 digest
of the expected `Authorization` header, and publishes it. The compiled function
exists only in AWS.

Terraform reads that published function through a data source rather than
managing its code, because managing it would put the digest into the state file
and into every plan. The consequence is an ordering constraint on a first-ever
provision, which `platform/web/README.md` documents: run `deploy.sh` once to
create the function, then `terraform apply`, then `deploy.sh` again.

### Planning this root, again

The same Postgres caveat as everywhere else in this root applies: without the
bastion tunnel, `terraform plan` produces a complete and correct plan for every
AWS resource and then fails on the three `postgresql_*` resources it cannot
reach. Phase 3 was applied with `-target` on its ten new resources for that
reason, after confirming the full plan read `10 to add, 0 to change, 0 to
destroy`. Repeating steps 1 through 4 above is still the way to plan this root
without the errors.

## The staging artifacts host

`artifacts.tf` serves published findings runs from
`artifacts.staging.changefabric.org`: a private S3 bucket
(`changefabric-artifacts-staging`, public access fully blocked, bucket owner
enforced, SSE-KMS under the shared `alias/cf-platform` CMK), a CloudFront
distribution on phase 1's wildcard certificate, a CloudFront public key and key
group, and one alias record.

Bytes never pass through the API in either direction. An upload is a presigned
`PUT` straight to S3, a machine download is a presigned `GET` straight back out,
and a browser gets CloudFront signed cookies rather than a proxied response.

### Objects expire after 180 days

`aws_s3_bucket_lifecycle_configuration.artifacts` **deletes** every object older
than 180 days. That is a real, data-destroying default, chosen because a findings
run is evidence about a commit that is long superseded by then. Extending the
window is a one-line change; doing it after the fact does not bring an expired
object back. A second rule aborts incomplete multipart uploads after seven days.

Versioning is deliberately **off**, unlike the app bucket. Nothing here is ever
overwritten (each run gets its own short id and therefore its own prefix), so a
version history would record only abandoned uploads, and it would need its own
noncurrent-version expiry to stay in agreement with the rule above.

### Two gates, and why there are two cache behaviors

The viewer-request function applies the same staging Basic Auth digest as the
other two surfaces. `trusted_key_groups` makes CloudFront itself require a valid
signed cookie. They answer different questions and both apply.

CloudFront evaluates the key group **before** it invokes the function. That was
measured against this distribution, not assumed: with both on one behavior, an
anonymous request is answered 403 by CloudFront and the function never runs, so
it can neither challenge for Basic Auth nor offer a first-time visitor a way to
get a cookie. The distribution is therefore split:

| Behavior | Key group | What it does |
| --- | --- | --- |
| `/v/*` | none | The entry point. Serves no bytes and never reaches the origin: the function answers every request with a 401 or a 302. |
| default | enforced | The objects. Every request, no exceptions, no list of file types to maintain. |

Enumerating protected behaviors by file extension and leaving the default open
was the alternative, and it was rejected: it protects the extensions somebody
remembered and serves the next one in the clear. Making the catch-all the
protected side means an unanticipated path fails closed.

### The signing key pair

Only the **public** half is in this repository, as
`cloudfront-signer.pub.pem`, and it is what `aws_cloudfront_public_key` reads.
The private half was generated locally with `openssl` and written straight to
`/cf-platform/staging/cloudfront-signer-private-key` with `aws ssm put-parameter`,
so it has never been in a plan, a state file, or a commit. The API reads it once
per cold start.

Rotating it:

```
export AWS_PROFILE=personal
openssl genrsa -out signer.key 2048
openssl rsa -in signer.key -pubout -out cloudfront-signer.pub.pem

aws ssm put-parameter --region us-east-1 --overwrite \
  --name /cf-platform/staging/cloudfront-signer-private-key \
  --type SecureString --value file://signer.key
rm signer.key

terraform apply    # adds the new public key to the key group
```

`create_before_destroy` on the public key means the replacement exists before the
old one goes, so no cookie already in a browser is invalidated mid-session.

### The S3 gateway endpoint

`endpoints.tf` gained `aws_vpc_endpoint.s3`, a **gateway** endpoint rather than
an interface one. Presigning needs no network, which is why publishing worked
before it existed; the `HeadObject` in `POST /v1/artifacts/:id/complete` does,
and without a path it hung until the function's timeout rather than failing. A
gateway endpoint is a route in a route table, so it costs nothing per hour and
nothing per gigabyte, and the VPC still has no internet gateway and no NAT.

### The Basic Auth function, again

`platform/web/artifacts-auth.function.js` is a template and
`platform/web/deploy-artifacts.sh` compiles the digest in and publishes it, the
same arrangement and for the same reason as the web app's. Terraform reads the
published function through a data source. On a first-ever provision, run
`deploy-artifacts.sh` once, then `terraform apply`.

### The KMS key policy grew a statement

CloudFront reads this bucket through an OAC as the `cloudfront.amazonaws.com`
service principal, which has no IAM identity for the key policy's root statement
to delegate to. Without the second statement in `kms.tf`, every object fetch
fails to decrypt and the host answers 502 for content that is present and
correct. The grant is decryption only, this account only, and via S3 only.

## What this root does not own

- The `changefabric.org` hosted zone, and every record `site/infra` or
  `telemetry/infra` already manages. This root only reads the zone id, adds its
  own certificate validation records, and adds three alias records:
  `api.staging.changefabric.org`, `app.staging.changefabric.org` and
  `artifacts.staging.changefabric.org`.
- The `cf-teams` DynamoDB table and everything else in `telemetry/infra`.
- The code of either Basic Auth CloudFront Function. See above.
- The CloudFront signing private key, which lives only in SSM.
