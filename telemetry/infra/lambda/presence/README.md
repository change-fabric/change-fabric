# presence (Capability B, plan section 6.2)

Container-image Ruby Lambda (`package_type = "Image"`), based on
`public.ecr.aws/lambda/ruby:3.4`, because the `ed25519` gem has a native C
extension that must link against the Lambda runtime. Handler: `handler.handler`.

## Environment variables (wired by Terraform)

- `PRESENCE_TABLE` = `cf-presence`
- `TEAMS_TABLE` = `cf-teams`
- `PRESENCE_TTL` = `900`
- `TS_SKEW_SECONDS` (e.g. `300`)

## Signing contract

See `../SIGNING.md` - the 7-field presence canonical-bytes scheme. The pst-side
hook must produce byte-identical canonical bytes or every signature fails.

## Packaging (run before `terraform apply`)

Generate a `Gemfile.lock` (once, so the image build is reproducible), then let
Terraform / the deployer build and push the image to ECR:

```sh
bundle lock                       # produces Gemfile.lock
docker build -t cf-presence .     # or via the Terraform docker/ECR pipeline
```
