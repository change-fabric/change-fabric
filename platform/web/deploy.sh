#!/usr/bin/env bash
# Publishes the staging web app.
#
# Three things happen here, in this order:
#
#   1. The Basic Auth CloudFront Function is compiled and published. The
#      credential is read from SSM at this moment and only the SHA-256 digest of
#      the expected Authorization header is written into the function source. The
#      plaintext never touches disk, never reaches a Terraform plan, and is never
#      committed. Rotating it is a put-parameter plus a re-run of this script.
#   2. dist/ syncs to the Terraform-managed bucket, hashed assets with a long
#      immutable cache and index.html with a short must-revalidate one, so a
#      deploy is visible on the next load rather than whenever a browser feels
#      like it.
#   3. The distribution is invalidated.
#
# Step 1 stands alone deliberately: platform/infra's distribution references the
# published function through a data source, so on a first-ever provision this
# script is run once to create the function, then `terraform apply` builds the
# distribution around it, then this script is run again to publish the site.
# Every run after that is a single run.
#
# Run `npm run build` in platform/web first.
set -euo pipefail

export AWS_PAGER=""

region="us-east-1"
credential_parameter="/cf-platform/staging/basic-auth-credential"
function_name="cf-platform-app-staging-basic-auth"
realm="staging"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
infra="$here/../infra"
dist="$here/dist"
template="$here/basic-auth.function.js"

# ---------------------------------------------------------------------------
# 1. Compile and publish the Basic Auth function.
# ---------------------------------------------------------------------------

# A temporary file, deleted on any exit path, because it is the one place the
# compiled function (digest included) exists outside AWS.
compiled="$(mktemp -t cf-app-basic-auth)"
trap 'rm -f "$compiled"' EXIT

credential="$(aws ssm get-parameter --region "$region" \
  --name "$credential_parameter" --with-decryption \
  --query 'Parameter.Value' --output text)"

if [ -z "$credential" ]; then
  echo "SSM parameter $credential_parameter is empty" >&2
  exit 1
fi

# The digest covers the whole Authorization header value, matching the existing
# artifacts-host precedent. printf, not echo, so no trailing newline is hashed.
authorization="Basic $(printf '%s' "$credential" | base64)"
digest="$(printf '%s' "$authorization" | shasum -a 256 | cut -d' ' -f1)"
unset credential authorization

sed -e "s/__CREDENTIAL_SHA256__/$digest/" -e "s/__REALM__/$realm/" \
  "$template" >"$compiled"

if aws cloudfront describe-function --region "$region" --name "$function_name" >/dev/null 2>&1; then
  etag="$(aws cloudfront describe-function --region "$region" --name "$function_name" \
    --query 'ETag' --output text)"
  echo "updating CloudFront function $function_name"
  etag="$(aws cloudfront update-function --region "$region" --name "$function_name" \
    --if-match "$etag" \
    --function-config "Comment=Staging Basic Auth gate for the change-fabric web app,Runtime=cloudfront-js-2.0" \
    --function-code "fileb://$compiled" \
    --query 'ETag' --output text)"
else
  echo "creating CloudFront function $function_name"
  etag="$(aws cloudfront create-function --region "$region" --name "$function_name" \
    --function-config "Comment=Staging Basic Auth gate for the change-fabric web app,Runtime=cloudfront-js-2.0" \
    --function-code "fileb://$compiled" \
    --query 'ETag' --output text)"
fi

aws cloudfront publish-function --region "$region" --name "$function_name" \
  --if-match "$etag" >/dev/null
echo "published CloudFront function $function_name"

# ---------------------------------------------------------------------------
# 2 and 3. Sync and invalidate, once the infrastructure around the function
# exists. On the bootstrap run it does not yet, which is not an error.
# ---------------------------------------------------------------------------

if [ -n "${APP_BUCKET:-}" ] && [ -n "${APP_DISTRIBUTION_ID:-}" ]; then
  bucket="$APP_BUCKET"
  distribution="$APP_DISTRIBUTION_ID"
else
  export AWS_PROFILE="${AWS_PROFILE:-personal}"
  bucket="$(terraform -chdir="$infra" output -raw app_bucket 2>/dev/null || true)"
  distribution="$(terraform -chdir="$infra" output -raw app_distribution_id 2>/dev/null || true)"
fi

if [ -z "$bucket" ] || [ -z "$distribution" ]; then
  echo "no app bucket or distribution yet; run 'terraform apply' in platform/infra, then re-run this script"
  exit 0
fi

if [ ! -f "$dist/index.html" ]; then
  echo "no build found at $dist; run 'npm run build' in platform/web first" >&2
  exit 1
fi

echo "syncing $dist -> s3://$bucket"
# Hashed assets are immutable and get a year. index.html is not hashed and must
# never be, or a deploy would be invisible until a cache expired.
aws s3 sync "$dist" "s3://$bucket" --delete \
  --exclude index.html \
  --cache-control "public, max-age=31536000, immutable"
aws s3 cp "$dist/index.html" "s3://$bucket/index.html" \
  --cache-control "public, max-age=60, must-revalidate" \
  --content-type "text/html"

echo "invalidating CloudFront $distribution"
aws cloudfront create-invalidation --distribution-id "$distribution" --paths "/*" >/dev/null

echo "deployed https://app.staging.changefabric.org"
