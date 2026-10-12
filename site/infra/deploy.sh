#!/usr/bin/env bash
# Publishes the built site: syncs site/dist to the Terraform-managed S3 bucket
# and invalidates the www CloudFront distribution so the new build is served
# immediately. Run `npm run build` in site/ first, then `terraform apply` in
# site/infra/, then this.
#
# Reads the bucket and distribution id from SITE_BUCKET/WWW_DISTRIBUTION_ID if
# set (CI: no Terraform state access needed, just the two ids as repo
# variables), else from Terraform outputs (local use).
set -euo pipefail

export AWS_PAGER=""

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dist="$here/../dist"

if [ ! -f "$dist/index.html" ]; then
  echo "no build found at $dist; run 'npm run build' in site/ first" >&2
  exit 1
fi

if [ -n "${SITE_BUCKET:-}" ] && [ -n "${WWW_DISTRIBUTION_ID:-}" ]; then
  bucket="$SITE_BUCKET"
  distribution="$WWW_DISTRIBUTION_ID"
else
  export AWS_PROFILE="${AWS_PROFILE:-personal}"
  bucket="$(terraform -chdir="$here" output -raw site_bucket)"
  distribution="$(terraform -chdir="$here" output -raw www_distribution_id)"
fi

echo "syncing $dist -> s3://$bucket"
# Only Vite's build output under assets/ carries a content hash in its
# filename, so only it may be cached for a year as immutable. Everything else
# (index.html, icons, the Open Graph image, brand/ art, anything later added
# to public/) keeps a stable URL across deploys and must revalidate, or a
# browser can hold a replaced file for a year. Deciding by directory instead of
# a list of exceptions means a new public file is safe by default.
aws s3 sync "$dist" "s3://$bucket" --delete \
  --exclude "assets/*" \
  --cache-control "public, max-age=60, must-revalidate"
aws s3 sync "$dist/assets" "s3://$bucket/assets" --delete \
  --cache-control "public, max-age=31536000, immutable"

# The raw spec markdown is fetched directly by agents/tools, so serve it as
# plain markdown text (not the octet-stream the sync would guess) with a short
# cache so a corrected spec propagates.
if compgen -G "$dist/spec/*.md" >/dev/null; then
  for md in "$dist"/spec/*.md; do
    aws s3 cp "$md" "s3://$bucket/spec/$(basename "$md")" \
      --content-type "text/markdown; charset=utf-8" \
      --cache-control "public, max-age=300, must-revalidate"
  done
fi

# The feed changes whenever CHANGELOG.md does, which is a spec release and not
# necessarily a site/VERSION bump, so it gets the same five-minute cache as the
# raw spec markdown, plus its feed content type.
if [ -f "$dist/changelog.xml" ]; then
  aws s3 cp "$dist/changelog.xml" "s3://$bucket/changelog.xml" \
    --content-type "application/rss+xml; charset=utf-8" \
    --cache-control "public, max-age=300, must-revalidate"
fi

echo "invalidating CloudFront $distribution"
aws cloudfront create-invalidation --distribution-id "$distribution" --paths "/*" >/dev/null

echo "deployed."
