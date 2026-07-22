# transcript_authorizer (Capability A, plan section 6.3)

Plain-zip Ruby Lambda, `ruby3.4` managed runtime. Handler: `handler.handler`.
API Gateway v2 HTTP API REQUEST authorizer with `enableSimpleResponses = true`,
attached only to `POST /transcripts`. Returns `{ isAuthorized: true/false }`.

Pure stdlib (`openssl`) - no gems, so no `bundle install` and no `vendor/`.

## Environment variables (wired by Terraform)

- `TELEMETRY_SECRET` - read from SSM `/cf-telemetry/api-secret` by Terraform.

## Packaging (run before `terraform apply`)

```sh
zip ../transcript_authorizer.zip handler.rb
```
