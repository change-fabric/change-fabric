#!/usr/bin/env bash
# Mirrors one upstream Mailpit release into the private ECR repository the
# Fargate task pulls from.
#
# This runs on a laptop or in CI, NEVER inside the VPC. That separation is the
# whole point: the VPC has no internet gateway and no NAT, so it can pull from
# ECR over interface endpoints but can never reach a public registry. Getting
# the image into ECR is therefore a step that happens somewhere with internet
# access, and the VPC only ever sees the result.
#
# Why this script exists at all, rather than an ECR pull-through cache rule:
# see "Why the image is mirrored" in platform/infra/README.md. Both of the
# reasons are hard blocks, not preferences.
#
# The source is ghcr.io, which is the Mailpit project's own registry, published
# by its own release workflow. It is byte-identical to the Docker Hub image:
# both registries serve the same manifest digest for the same tag, which this
# script verifies before it pushes rather than asking anyone to trust the claim.
#
#   ./mirror-image.sh v1.30.6
set -euo pipefail

export AWS_PAGER=""
export AWS_PROFILE="${AWS_PROFILE:-personal}"

tag="${1:-}"
if [ -z "$tag" ]; then
  echo "usage: $0 <mailpit tag, for example v1.30.6>" >&2
  exit 1
fi

region="us-east-1"
repository="cf-platform/mailpit"
source_image="ghcr.io/axllent/mailpit"

# ARM64, matching the task definition and every other piece of compute in this
# estate. The upstream manifest is genuinely multi-arch, so this selects rather
# than substitutes.
platform="linux/arm64"

account="$(aws sts get-caller-identity --query Account --output text)"
registry="$account.dkr.ecr.$region.amazonaws.com"

# ---------------------------------------------------------------------------
# Confirm the two upstream registries agree before anything is pushed.
#
# A mismatch means one of them is serving something the other is not, and the
# right response is to stop and find out why, not to pick one.
# ---------------------------------------------------------------------------

accept='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json'

ghcr_token="$(curl -fsS "https://ghcr.io/token?scope=repository:axllent/mailpit:pull&service=ghcr.io" | jq -r .token)"
ghcr_digest="$(curl -fsSI -H "Authorization: Bearer $ghcr_token" -H "Accept: $accept" \
  "https://ghcr.io/v2/axllent/mailpit/manifests/$tag" \
  | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }')"

hub_token="$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:axllent/mailpit:pull" | jq -r .token)"
hub_digest="$(curl -fsSI -H "Authorization: Bearer $hub_token" -H "Accept: $accept" \
  "https://registry-1.docker.io/v2/axllent/mailpit/manifests/$tag" \
  | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }')"

if [ -z "$ghcr_digest" ]; then
  echo "no manifest for $tag on ghcr.io" >&2
  exit 1
fi

if [ "$ghcr_digest" != "$hub_digest" ]; then
  echo "upstream registries disagree for $tag:" >&2
  echo "  ghcr.io:    $ghcr_digest" >&2
  echo "  docker.io:  $hub_digest" >&2
  exit 1
fi

echo "upstream digest confirmed on both registries: $ghcr_digest"

# ---------------------------------------------------------------------------
# Pull by digest, tag, push.
# ---------------------------------------------------------------------------

echo "pulling $source_image@$ghcr_digest ($platform)"
docker pull --platform "$platform" "$source_image@$ghcr_digest"

target="$registry/$repository:$tag"
docker tag "$source_image@$ghcr_digest" "$target"

aws ecr get-login-password --region "$region" \
  | docker login --username AWS --password-stdin "$registry"

echo "pushing $target"
docker push "$target"

echo
echo "mirrored mailpit $tag"
echo "set mailpit_image_tag = \"$tag\" in platform/infra and apply"
