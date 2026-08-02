#!/usr/bin/env bash
# Publishes the artifacts host's viewer-request CloudFront Function.
#
# This is deploy.sh's step 1 for a different surface, and nothing else: there is
# no bucket to sync, because the artifacts bucket's contents are published by the
# API through presigned URLs rather than by a deploy.
#
# The staging credential is read from SSM at this moment and only the SHA-256
# digest of the expected Authorization header is written into the function
# source. The plaintext never touches disk, never reaches a Terraform plan, and
# is never committed. Rotating it is a put-parameter plus a re-run of this
# script, exactly as for the web app.
#
# Ordering on a first-ever provision, same as deploy.sh: platform/infra's
# distribution references the published function through a data source, so run
# this once to create the function, then `terraform apply` builds the
# distribution around it. Every run after that is a single run.
set -euo pipefail

export AWS_PAGER=""
export AWS_PROFILE="${AWS_PROFILE:-personal}"

region="us-east-1"
credential_parameter="/cf-platform/staging/basic-auth-credential"
function_name="cf-platform-artifacts-staging-auth"
realm="staging"
app_origin="https://app.staging.changefabric.org"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
infra="$here/../infra"
template="$here/artifacts-auth.function.js"

# A temporary file, deleted on any exit path, because it is the one place the
# compiled function (digest included) exists outside AWS.
compiled="$(mktemp -t cf-artifacts-auth)"
trap 'rm -f "$compiled"' EXIT

credential="$(aws ssm get-parameter --region "$region" \
  --name "$credential_parameter" --with-decryption \
  --query 'Parameter.Value' --output text)"

if [ -z "$credential" ]; then
  echo "SSM parameter $credential_parameter is empty" >&2
  exit 1
fi

# The digest covers the whole Authorization header value, matching the web app's
# gate exactly. printf, not echo, so no trailing newline is hashed.
authorization="Basic $(printf '%s' "$credential" | base64)"
digest="$(printf '%s' "$authorization" | shasum -a 256 | cut -d' ' -f1)"
unset credential authorization

# The app origin contains slashes, so it is substituted with a different
# delimiter rather than escaped.
sed -e "s/__CREDENTIAL_SHA256__/$digest/" \
    -e "s/__REALM__/$realm/" \
    -e "s|__APP_ORIGIN__|$app_origin|" \
  "$template" >"$compiled"

comment="Staging Basic Auth gate and viewer-cookie redirect for the change-fabric artifacts host"

if aws cloudfront describe-function --region "$region" --name "$function_name" >/dev/null 2>&1; then
  etag="$(aws cloudfront describe-function --region "$region" --name "$function_name" \
    --query 'ETag' --output text)"
  echo "updating CloudFront function $function_name"
  etag="$(aws cloudfront update-function --region "$region" --name "$function_name" \
    --if-match "$etag" \
    --function-config "Comment=$comment,Runtime=cloudfront-js-2.0" \
    --function-code "fileb://$compiled" \
    --query 'ETag' --output text)"
else
  echo "creating CloudFront function $function_name"
  etag="$(aws cloudfront create-function --region "$region" --name "$function_name" \
    --function-config "Comment=$comment,Runtime=cloudfront-js-2.0" \
    --function-code "fileb://$compiled" \
    --query 'ETag' --output text)"
fi

aws cloudfront publish-function --region "$region" --name "$function_name" \
  --if-match "$etag" >/dev/null
echo "published CloudFront function $function_name"

# Nothing to sync. The invalidation is still worth doing when the distribution
# exists, because a redirect or a 401 this function produced may be sitting in
# an edge cache from before the change.
if [ -n "${ARTIFACTS_DISTRIBUTION_ID:-}" ]; then
  distribution="$ARTIFACTS_DISTRIBUTION_ID"
else
  distribution="$(terraform -chdir="$infra" output -raw artifacts_distribution_id 2>/dev/null || true)"
fi

if [ -z "$distribution" ]; then
  echo "no artifacts distribution yet; run 'terraform apply' in platform/infra"
  exit 0
fi

echo "invalidating CloudFront $distribution"
aws cloudfront create-invalidation --distribution-id "$distribution" --paths "/*" >/dev/null

echo "published https://artifacts.staging.changefabric.org"
