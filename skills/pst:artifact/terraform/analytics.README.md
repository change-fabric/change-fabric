# Optional view-counter analytics

A privacy-light, per-artifact view counter that the published static pages can
call from the browser to display a view count. It is **opt-in and off by
default** - leaving `enable_analytics` unset creates none of these resources and
changes nothing about the base site.

## Enabling

Set the toggle in your `terraform.tfvars`:

```hcl
enable_analytics = true
```

Optionally override the table name (defaults to `<domain>-views`):

```hcl
analytics_table_name = "my-custom-views-table"
```

Then `terraform apply`.

## Wiring it into the studio

After `apply`, copy the `analytics_endpoint` output into the studio's
`plans.config.json` as `analyticsEndpoint`:

```jsonc
{
  "analyticsEndpoint": "https://<id>.lambda-url.<region>.on.aws/",
}
```

The published pages call `GET <analyticsEndpoint>?id=<artifactId>` where `id` is
the **short artifact id**. The endpoint increments the counter and returns the
new total:

```json
{ "id": "abc123", "views": 42 }
```

## What it provisions

- A **DynamoDB table** (on-demand / `PAY_PER_REQUEST`), keyed by the string
  `id`, storing a numeric `views` attribute incremented atomically.
- A **Node.js 20 Lambda** behind a **Function URL** (`authorization_type =
NONE`), with CORS scoped to `https://<domain>`.
- A least-privilege **IAM role** (CloudWatch Logs + `UpdateItem`/`GetItem` on the
  one table) and a **CloudWatch log group** with 14-day retention.

## Cost

Effectively nothing at low traffic: DynamoDB on-demand bills per request with no
idle cost, and the Lambda's invocations sit comfortably inside the perpetual
free tier. Logs auto-expire after 14 days.

## Privacy

The table stores **only an incrementing integer per artifact id** - no PII, no
IP addresses, no headers, no user agents, nothing else is logged or persisted.
