#!/usr/bin/env bash
# Stages the Lambda package into build/package (what main.tf zips): the handler
# files, the shared canonical/cbor/totp/verifier files copied from
# scripts/approval_console, and the gems from lambda/Gemfile.lock installed in
# a linux/arm64 Lambda build container so the package matches the runtime.
# Re-runnable: it rebuilds the directory from scratch every time. Needs Docker
# and network for the gems; no AWS access.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="$here/build/package"
image="${CF_LAMBDA_BUILD_IMAGE:-public.ecr.aws/sam/build-ruby3.4:latest-arm64}"

rm -rf "$out"
mkdir -p "$out/shared"
cp "$here"/lambda/*.rb "$out/"
for name in canonical cbor totp verifier; do
  cp "$repo/scripts/approval_console/$name.rb" "$out/shared/$name.rb"
done

if [ "${CF_SKIP_GEMS:-0}" = "1" ]; then
  echo "CF_SKIP_GEMS=1: gems not installed (the package will not run)"
else
  cp "$here/lambda/Gemfile" "$here/lambda/Gemfile.lock" "$out/"
  docker run --rm --platform linux/arm64 -v "$out:/var/task" -w /var/task "$image" \
    bash -c 'bundle config set --local path vendor/bundle && bundle config set --local deployment true && bundle config set --local without development:test && bundle install --quiet && rm -rf vendor/bundle/ruby/*/cache .bundle'
  # The runtime resolves gems from vendor/bundle without Bundler, so the
  # Bundler files are not needed in the package.
  rm -f "$out/Gemfile" "$out/Gemfile.lock"
fi

echo "staged $(find "$out" -type f | wc -l | tr -d ' ') files in $out"
