# secret_scanner (Capability C, plan section 6.4)

Plain-zip Ruby Lambda, `ruby3.4` managed runtime. Handler: `handler.handler`.
One implementation, two front ends: the `cf-telemetry` DynamoDB Streams trigger
(freshness) and the hourly EventBridge sweep (durable catch-all over the sparse
`gsi-unscanned` index). Detection lives in the swappable `Detector` module
(`detector.rb`) - a pure-Ruby regex ruleset plus a Shannon-entropy-gated
catch-all, no external binary.

Needs stdlib (`json`, `base64`, `digest`, `time`) plus `aws-sdk-dynamodb`,
`aws-sdk-s3`, and `aws-sdk-ssm`. No native gems, so no container build.

## Environment variables (wired by Terraform)

- `TABLE_NAME` = `cf-telemetry`
- `UNSCANNED_INDEX` = `gsi-unscanned`
- `BUCKET_NAME` = `cf-transcripts`
- `NOTIFICATIONS_TABLE` = `cf-notifications`
- `SWEEP_CURSOR_PARAM` = `/cf-secret-scan/cursor`
- `SWEEP_PAGE_LIMIT` (e.g. `100`)

## Packaging (run before `terraform apply`)

```sh
bundle config set --local path vendor/bundle
bundle install
zip -r ../secret_scanner.zip handler.rb detector.rb vendor
```
