#!/usr/bin/env bash
# Compiles and publishes the Basic Auth CloudFront Function in front of the
# staging Mailpit UI.
#
# This is platform/web/deploy.sh's first step and nothing else: there is no
# bundle to sync, because the origin is a running container rather than a bucket
# of files. The credential is read from SSM at this moment and only the SHA-256
# digest of the expected Authorization header is written into the function
# source. The plaintext never touches disk, never reaches a Terraform plan, and
# is never committed. Rotating it is a put-parameter plus a re-run of this script
# and of platform/web/deploy.sh, which read the same one parameter.
#
# Ordering on a first-ever provision, same as the other two surfaces:
# platform/infra references the published function through a data source, so run
# this script once to create the function, then `terraform apply`.
set -euo pipefail

export AWS_PAGER=""
export AWS_PROFILE="${AWS_PROFILE:-personal}"

region="us-east-1"
credential_parameter="/cf-platform/staging/basic-auth-credential"
function_name="cf-platform-mailpit-staging-basic-auth"
realm="staging"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
infra="$here/../infra"
template="$here/basic-auth.function.js"

# A temporary file, deleted on any exit path, because it is the one place the
# compiled function (digest included) exists outside AWS.
compiled="$(mktemp -t cf-mailpit-basic-auth)"
trap 'rm -f "$compiled"' EXIT

credential="$(aws ssm get-parameter --region "$region" \
  --name "$credential_parameter" --with-decryption \
  --query 'Parameter.Value' --output text)"

if [ -z "$credential" ]; then
  echo "SSM parameter $credential_parameter is empty" >&2
  exit 1
fi

# The digest covers the whole Authorization header value, matching the web app
# and artifacts hosts. printf, not echo, so no trailing newline is hashed.
authorization="Basic $(printf '%s' "$credential" | base64)"
digest="$(printf '%s' "$authorization" | shasum -a 256 | cut -d' ' -f1)"
unset credential authorization

sed -e "s/__CREDENTIAL_SHA256__/$digest/" -e "s/__REALM__/$realm/" \
  "$template" >"$compiled"

comment="Staging Basic Auth gate for the change-fabric mailpit UI"

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

# Republishing the function does not change the distribution, but it also does
# not take effect on a cached 401 response, so the distribution is invalidated
# when there is one to invalidate. On the bootstrap run there is not, which is
# not an error.
distribution="${MAILPIT_DISTRIBUTION_ID:-$(terraform -chdir="$infra" output -raw mailpit_distribution_id 2>/dev/null || true)}"

if [ -z "$distribution" ]; then
  echo "no mailpit distribution yet; run 'terraform apply' in platform/infra"
  exit 0
fi

echo "invalidating CloudFront $distribution"
aws cloudfront create-invalidation --distribution-id "$distribution" --paths "/*" >/dev/null
echo "gated https://mailpit.staging.changefabric.org"
