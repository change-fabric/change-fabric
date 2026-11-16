# change-fabric telemetry backend infrastructure

Terraform for the backend behind `api.changefabric.org`, `personal` AWS account,
us-east-1: one CMK, four DynamoDB tables (`cf-telemetry`, `cf-presence`,
`cf-teams`, `cf-notifications`), the `cf-transcripts` bucket, five Ruby Lambdas
under `lambda/`, the HTTP API with its shared-secret authorizer, and the custom
domain. The request signing contract is `lambda/SIGNING.md`.

## State backend

The shared bucket `changefabric-tfstate-569032832755` (see
`site/infra/README.md`), key `changefabric-telemetry/terraform.tfstate`.

## Before the first apply

1. Seed `/cf-telemetry/api-secret` as an SSM SecureString. The same value is the
   SessionEnd hook's `x-api-key`.
2. `presence` and `notifications` link the native `ed25519` gem, so they ship as
   ECR images: create the two repos (`-target` the `aws_ecr_repository`
   resources), `docker build` and push from `lambda/presence` and
   `lambda/notifications`, then pass `presence_image_uri` and
   `notifications_image_uri`. Apply fails without them by design.
3. The three zip Lambdas are packaged from their directories at plan time, so
   vendor their gems first.

## Apply

```
export AWS_PROFILE=personal
cd telemetry/infra
terraform init
terraform apply -var "presence_image_uri=..." -var "notifications_image_uri=..."
```

The five Lambda log groups in `observability.tf` were imported into state; a
rebuild from empty state must `terraform import` them first. Terraform owns the
tables, not their rows (`cf-teams` rows come from `cf_team_init.rb`).
