# Mailpit on staging

`https://mailpit.staging.changefabric.org` is the mailbox staging actually
delivers to. It exists because SES is in the sandbox on this account: a
verification or invitation mail addressed to anything that is not a pre-verified
identity is rejected, and `platform/api` logs that rejection and carries on
rather than failing the sign-up it belongs to. That was the right call and it
still is, but it left staging with mail nobody could read. Mailpit accepts the
message on SMTP 1025 inside the VPC and renders it in a browser.

Everything about it is deliberately unglamorous. Messages live in the task's
memory, capped at 500, and a redeploy loses them. It is a window onto what the
API just sent, not a mail store.

## What is here

| File | What it is |
| --- | --- |
| `basic-auth.function.js` | Template for the viewer-request CloudFront Function. The digest is a placeholder; the compiled version exists only in AWS. |
| `deploy.sh` | Reads the shared staging credential from SSM, compiles its SHA-256 digest into the function, publishes it, invalidates the distribution. |
| `mirror-image.sh` | Copies one upstream Mailpit release into the private ECR repository the Fargate task pulls from. Runs outside the VPC, never inside it. |

The Terraform is in `platform/infra/mailpit.tf`, with the endpoint changes it
needs in `platform/infra/endpoints.tf`.

## The gate is the same gate

`deploy.sh` reads `/cf-platform/staging/basic-auth-credential`, the one
parameter every staging surface reads. There is no second credential and no
second parameter. Rotating it is a `put-parameter --overwrite` followed by a
re-run of this script, `platform/web/deploy.sh` and
`platform/web/deploy-artifacts.sh`, because all three carry a compiled digest of
the same value.

Mailpit has no authentication of its own turned on. It does not need any: the
only route to port 8025 is through the internal load balancer, the only thing in
front of that is this distribution, and the first thing the distribution does
with a request is run this function.

## Ordering, on a first-ever provision

`platform/infra` reads the published function through a data source, so the
function has to exist before a plan will even complete:

```
export AWS_PROFILE=personal

./deploy.sh                       # creates and publishes the function
./mirror-image.sh v1.30.6         # puts the image in ECR
cd ../infra && terraform apply    # builds everything around both
cd ../mailpit && ./deploy.sh      # invalidates, now that there is a distribution
```

## Upgrading Mailpit

```
export AWS_PROFILE=personal
./mirror-image.sh v1.31.0
```

then set `mailpit_image_tag = "v1.31.0"` in `platform/infra` and apply. The ECR
repository is immutable-tagged, so re-mirroring a tag that is already there
fails rather than quietly changing what staging runs.

`mirror-image.sh` pulls from `ghcr.io/axllent/mailpit`, which is the Mailpit
project's own registry, and refuses to push unless Docker Hub serves the exact
same manifest digest for that tag. Two first-party registries agreeing is a
stronger provenance statement than either one alone, and it is checked rather
than assumed.

## Reading the mailbox without a browser

Mailpit's JSON API is behind the same gate, so it takes the same credential:

```
curl -su changefabric:changefabric \
  https://mailpit.staging.changefabric.org/api/v1/messages | jq '.messages[0]'

curl -su changefabric:changefabric \
  https://mailpit.staging.changefabric.org/api/v1/message/<id> | jq -r .Text
```
