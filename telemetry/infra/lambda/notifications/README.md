# notifications (Capability C delivery, plan section 6.5)

Container-image Ruby Lambda (`package_type = "Image"`), based on
`public.ecr.aws/lambda/ruby:3.4`, because the `ed25519` gem has a native C
extension. Handler: `handler.handler`. Serves both `POST /notifications` (poll)
and `POST /notifications/ack` (ack) from one integration, dispatched by request
path inside the handler.

## Environment variables (wired by Terraform)

- `NOTIFICATIONS_TABLE` = `cf-notifications`
- `TEAMS_TABLE` = `cf-teams`
- `TS_SKEW_SECONDS` (e.g. `300`)

## Signing contract

See `../SIGNING.md` - the 4-field poll scheme and 6-field ack scheme. Distinct
from presence's 7-field scheme. The pst-side hooks must match byte-for-byte.

## Packaging (run before `terraform apply`)

```sh
bundle lock                            # produces Gemfile.lock
docker build -t cf-notifications .     # or via the Terraform docker/ECR pipeline
```
