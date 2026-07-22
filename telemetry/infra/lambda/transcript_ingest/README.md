# transcript_ingest (Capability A, plan section 6.1)

Plain-zip Ruby Lambda, `ruby3.4` managed runtime. Handler: `handler.handler`.

Needs only stdlib (`json`, `base64`, `digest`, `time`) plus `aws-sdk-dynamodb`
and `aws-sdk-s3`, vendored into the zip. No native gems, so no container build.

## Environment variables (wired by Terraform)

- `TABLE_NAME` = `cf-telemetry`
- `BUCKET_NAME` = `cf-transcripts`
- `INLINE_MAX` = `350000`

## Packaging (run before `terraform apply`)

The deployer vendors gems into the zip. From this directory:

```sh
bundle config set --local path vendor/bundle
bundle install
zip -r ../transcript_ingest.zip handler.rb vendor
```

`terraform apply` uploads `transcript_ingest.zip` with handler `handler.handler`.
