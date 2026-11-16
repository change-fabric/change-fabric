# changefabric.org infrastructure

Terraform for the changefabric.org static site, `personal` AWS account,
us-east-1: a private S3 site bucket read by CloudFront via OAC, a www
distribution plus an apex distribution that 301-redirects to www, one ACM cert,
Route53 aliases, a security-headers policy (HSTS without `includeSubDomains`,
since other roots own the subdomains), and the GitHub OIDC deploy role.

## State backend

S3 bucket `changefabric-tfstate-569032832755`, created once by hand (versioned)
because Terraform cannot create its own backend. The other roots reuse it under
their own keys.

## Apply

```
export AWS_PROFILE=personal
cd site/infra
terraform init
terraform apply
```

## Publish

Production deploys only from a `site/v*` tag through
`.github/workflows/deploy-site.yml` (see `RELEASING.md`). By hand:
`cd site && npm run build && cd infra && ./deploy.sh`. The sync is `--delete`
against a versioned bucket, so a bad publish can be rolled back; non-current
versions expire after 30 days.

The OIDC trust policy in `oidc.tf` only trusts `ref:refs/tags/site/v*`, so a run
on `main` cannot deploy production.
