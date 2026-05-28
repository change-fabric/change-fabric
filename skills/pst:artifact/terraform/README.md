# Artifacts Studio - static-site hosting (Terraform)

Provisions private, self-hosted "Claude Artifacts"-style static-site hosting on AWS:
CloudFront in front of a private S3 origin (Origin Access Control), a DNS-validated
ACM certificate, and Route53 A/AAAA alias records. The site is served at a
configurable subdomain (default example `artifacts.pstaylor.net`) and is **no-index
by default** (every response carries `X-Robots-Tag: noindex, nofollow`).

## Prerequisites

- A **Route53 public hosted zone for the apex already exists** (e.g. `pstaylor.net`).
  This module looks the zone up - it does not create it.
- An AWS profile configured locally (the profile named in `aws_profile`) with
  permission to manage S3, CloudFront, ACM, and Route53.
- Terraform `>= 1.5`.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit values
terraform init
terraform apply
```

That's the whole one-time setup. Re-running `terraform apply` is safe and
idempotent - nothing is recreated unless inputs change.

> **Heads up:** the first apply waits on CloudFront distribution deployment and
> ACM DNS validation, which together typically take **15–30 minutes**. Subsequent
> applies are fast.

## Conventions

- **Bucket name defaults to the domain** (`var.domain`), so `artifacts.pstaylor.net`
  gives a bucket named `artifacts.pstaylor.net`.
- ACM certificates for CloudFront must live in **us-east-1**; the module uses an
  aliased `aws.us_east_1` provider for the cert and its validation, so the primary
  `aws_region` can be anything.
- Artifact permalinks use stable-id routing: artifacts are stored at
  `/p/<id>/index.html`, while shared URLs look like `/p/<id>/<cosmetic-slug>`. A
  CloudFront viewer-request function (`cloudfront_function.js`) rewrites any `/p/`
  request to its stored path and discards the slug.

## Content publishing

Terraform provisions infrastructure only. **It does not upload site content.**
Syncing the Astro build output to S3 and invalidating the CloudFront cache is
handled separately by `scripts/publish.py` (`aws s3 sync` + a CloudFront
invalidation against the `distribution_id` output).

## Outputs

| Output                     | Purpose                                             |
| -------------------------- | --------------------------------------------------- |
| `distribution_id`          | CloudFront distribution id (used for invalidations) |
| `distribution_domain_name` | `dxxxx.cloudfront.net`                              |
| `bucket_name`              | s3 sync target                                      |
| `certificate_arn`          | validated ACM certificate ARN                       |
| `published_url_base`       | `https://<domain>`                                  |
