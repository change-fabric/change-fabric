# changefabric.org infrastructure

Terraform for the changefabric.org static site, in the `personal` AWS account,
us-east-1 (CloudFront requires its ACM cert there). All resources are real
Terraform: an S3 site bucket (private, read only by CloudFront via OAC), two
CloudFront distributions (www serves the site, apex 301-redirects to www through
a CloudFront Function), an ACM cert covering both hosts, and Route53 alias
records in the existing hosted zone `Z085992826QJCTEIBCCHA`.

## State backend

Remote state lives in an S3 bucket, `changefabric-tfstate-569032832755`.
Terraform cannot create its own backend before it exists, so the state bucket is
the one resource bootstrapped once by hand:

```
export AWS_PROFILE=personal
aws s3api create-bucket --bucket changefabric-tfstate-569032832755 --region us-east-1
aws s3api put-bucket-versioning \
  --bucket changefabric-tfstate-569032832755 \
  --versioning-configuration Status=Enabled
```

## Provision

```
export AWS_PROFILE=personal
cd site/infra
terraform init
terraform apply
```

The apply creates the cert and waits for DNS validation (the validation records
are created in the same run), then the distributions and Route53 records. A
first apply takes several minutes while CloudFront deploys.

## Publish the site

```
cd site
npm run build
cd infra
./deploy.sh
```

`deploy.sh` reads the bucket and distribution id from Terraform outputs, syncs
`site/dist`, and invalidates CloudFront.

The sync is `--delete` against the live production bucket, so the bucket is
versioned: a bad build or a run from the wrong directory can be undone rather than
rebuilt from whichever commit is believed to be good. Non-current versions expire
after 30 days.

## Security headers

Both distributions attach `aws_cloudfront_response_headers_policy.site`: HSTS for
one year, `nosniff`, `X-Frame-Options: DENY`, and
`Referrer-Policy: strict-origin-when-cross-origin`. Applied at the edge, so a
static site on S3 gets them without an origin that can run code.

HSTS deliberately does NOT set `includeSubDomains` or `preload`. This root owns
the apex and www; `api.changefabric.org` and the staging hosts belong to other
roots, and committing them to HTTPS-only for a year from here would be this root
making a promise on another root's behalf. The reasoning is repeated at the
resource in `main.tf`.

Verify against the live site rather than the plan:

```
curl -sSI https://www.changefabric.org/ | grep -i -E 'strict-transport|x-frame|nosniff|referrer'
```

## CI/CD

`.github/workflows/deploy-site.yml` runs this same publish step when a
`site/v*` tag is pushed, not on merges to `main`. Merging stages the change;
the tag ships it (`RELEASING.md`). It authenticates to AWS via GitHub's OIDC
provider (no long-lived keys). `oidc.tf` defines the IAM role it assumes,
trusted only for `repo:change-fabric/change-fabric` pushes of a
`refs/tags/site/v*` ref, so a run on any branch cannot deploy. Re-apply this
module once before the first tag deploy: the previous trust policy matched
`refs/heads/main` and will reject the tag run. The workflow reads
`SITE_BUCKET`/`WWW_DISTRIBUTION_ID`/
`DEPLOY_SITE_ROLE_ARN` from repo variables instead of running Terraform, so CI
never needs state-backend access; set them once after `terraform apply` from
this module's outputs (`site_bucket`, `www_distribution_id`,
`deploy_site_role_arn`).
