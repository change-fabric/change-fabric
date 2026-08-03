# change-fabric telemetry backend infrastructure

Terraform for the shared AWS backend behind `api.changefabric.org`, in the
`personal` AWS account, us-east-1. It provisions three capabilities on one HTTP
API: transcript telemetry (Capability A), live contributor presence (B), and
secret-leak detection + notification (C). See
`/tmp/pst-change-fabric-telemetry-poc/plan.md` for the design; this root
implements section 8.

What it creates: one CMK (`alias/cf-backend`); four DynamoDB tables
(`cf-telemetry` with a stream and the `gsi-unscanned` index, `cf-presence`,
`cf-teams`, `cf-notifications`); the private, versioned, lifecycle-purged
`cf-transcripts` S3 bucket; five Ruby Lambdas (three plain-zip, two ECR
container images); the DynamoDB-stream and hourly-EventBridge triggers for the
scanner; an SSM sweep cursor; least-privilege IAM per Lambda; the HTTP API with
four routes plus the shared-secret authorizer; and the ACM cert, custom domain,
and Route53 alias for `api.changefabric.org`.

This is a separate root from `site/infra`. It shares the state backend bucket and
reads the `changefabric.org` hosted zone, but manages neither.

## State backend

Remote state lives in the **existing** bucket
`changefabric-tfstate-569032832755` (the one `site/infra` already bootstrapped)
under a new key, `changefabric-telemetry/terraform.tfstate`. There is nothing new
to bootstrap: the bucket is reused as-is. If it somehow does not exist yet, create
it once as in `site/infra/README.md`.

## Before the first apply

Three things must exist before `terraform apply` succeeds. Each is out of band on
purpose so no secret and no built artifact lands in the repo or in a default.

### 1. Seed the transcript shared secret (SSM SecureString)

The `/transcripts` authorizer reads `/cf-telemetry/api-secret` at deploy time and
injects it into the authorizer's env. Create it once:

```
export AWS_PROFILE=personal
aws ssm put-parameter \
  --name /cf-telemetry/api-secret \
  --type SecureString \
  --value "$(openssl rand -hex 32)" \
  --region us-east-1
```

The same value goes into the `SessionEnd` hook's `x-api-key`. Rotating it is a
`put-parameter --overwrite` plus a re-apply (to refresh the authorizer env).

### 2. Build and push the two container images

`presence` and `notifications` link the native `ed25519` gem, so they ship as ECR
container images, not zips. **Apply will fail without valid `image_uri` values**
(both variables have no default by design). The ECR repositories are created by
this root, so the order is: apply once to create the repos (it will stop at the
Lambdas needing an image), or `terraform apply -target=aws_ecr_repository.presence
-target=aws_ecr_repository.notifications` first; then build, push, and set the
variables:

```
export AWS_PROFILE=personal
PRESENCE_REPO=$(terraform output -raw presence_ecr_repository_url)
NOTIFS_REPO=$(terraform output -raw notifications_ecr_repository_url)

aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin "${PRESENCE_REPO%/*}"

# from each Lambda's build context (see lambda/presence, lambda/notifications):
docker build -t "$PRESENCE_REPO:v1" lambda/presence
docker push  "$PRESENCE_REPO:v1"
docker build -t "$NOTIFS_REPO:v1" lambda/notifications
docker push  "$NOTIFS_REPO:v1"
```

Then pass the pushed references at apply (or put them in a `*.tfvars`):

```
terraform apply \
  -var "presence_image_uri=$PRESENCE_REPO:v1" \
  -var "notifications_image_uri=$NOTIFS_REPO:v1"
```

### 3. The three plain-zip Lambda directories must be built

`transcript_ingest`, `transcript_authorizer`, and `secret_scanner` are zipped
from `lambda/<name>/` at plan time (`archive_file`). Each needs its `handler.rb`
and vendored gems present (the Lambda build step owns that). The zip is packaged
from whatever is in the directory, so build before apply.

## Provision

```
export AWS_PROFILE=personal
cd telemetry/infra
terraform init
terraform apply \
  -var "presence_image_uri=<pushed presence image>" \
  -var "notifications_image_uri=<pushed notifications image>"
```

The apply creates the cert and waits for DNS validation (the validation records
are written in the same run against the existing zone), then the domain, mapping,
and alias record. Outputs include the API URL, the four table names, the bucket
name, the CMK arn, and the two ECR repo URLs.

## Log groups are imported, not created

`observability.tf` declares the five Lambda log groups so they carry a retention
policy. Before it existed, the Lambda service created them implicitly on first
invoke with the default retention, which is never: `/aws/lambda/cf-secret-scanner`
alone had reached 238 MB from an hourly job.

**They already exist in AWS.** A fresh `terraform apply` against this state will
fail with `ResourceAlreadyExistsException` unless they are in state first. They
were imported once with:

```
for pair in \
  "transcript_ingest:cf-transcript-ingest" \
  "transcript_authorizer:cf-transcript-authorizer" \
  "presence:cf-presence" \
  "secret_scanner:cf-secret-scanner" \
  "notifications:cf-notifications-api"; do
  key=${pair%%:*}; name=${pair##*:}
  terraform import \
    -var "presence_image_uri=..." -var "notifications_image_uri=..." \
    "aws_cloudwatch_log_group.lambda[\"$key\"]" "/aws/lambda/$name"
done
```

Only needed again if this root is ever rebuilt from empty state against existing
Lambdas.

Note that applying a retention policy **deletes** events older than the window.
That is the intent, and it is stated here rather than left to be discovered.

## Two Lambdas are deliberately not tagged yet

The `default_tags` block in `main.tf` was applied with `-target` across every
resource in this root except `aws_lambda_function.transcript_ingest`,
`transcript_authorizer` and `secret_scanner`.

Those three plan a `source_code_hash` change as well as a tag change, and the two
cannot be separated: the deployed production code and the code in this repository
are not the same bytes. Applying them would have shipped an untested code change
to a live function as a side effect of adding a tag. They pick up their tags on
the next intentional deploy of this root.

## Runtime data this root does not own

- `cf-teams` rows are seeded by `cf-team-init` (a `PutItem` of a team's public
  key). Terraform owns the empty table, not its contents.
- `cf-notifications` rows are written only by the scanner at runtime.
- The `/cf-secret-scan/cursor` SSM parameter is created empty (`{}`) and then
  overwritten by the scanner every run; Terraform ignores changes to its value.
- Team **private** keys never touch Terraform or AWS; only public keys reach
  `cf-teams`, public by design.
