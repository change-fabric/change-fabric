#!/usr/bin/env bash
# Redeploys the approval console Lambda from one exact, merged commit. Prompt-free:
# running it is the approval. It never recreates the function or its URL (the URL
# host is the passkey rpId): a plan that would replace either is refused.
#
#   CF_AWS_PROFILE=<profile> CF_ALERT_EMAIL=<address> CF_CLAIM_REPOS=<owner/repo[,owner/repo]> \
#     approval_console/infra/redeploy.sh <full 40-character commit sha>
#
# Refuses unless, after `git fetch origin main`, this checkout's HEAD equals the
# sha, the sha is an ancestor of origin/main, the working tree is clean, and the
# AWS account is the expected one (CF_EXPECTED_ACCOUNT, default the state
# bucket's account). Then it builds with build.sh, plans, checks the plan, applies.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
want="${1:-}"
expected_account="${CF_EXPECTED_ACCOUNT:-569032832755}"

refuse() { echo "redeploy.sh: refusing: $*" >&2; exit 1; }

[[ "$want" =~ ^[0-9a-f]{40}$ ]] || refuse "pass the full 40-character commit sha to deploy as the only argument"

cd "$repo"
git fetch --quiet origin main || refuse "git fetch origin main failed"
head="$(git rev-parse HEAD)"
[ "$head" = "$want" ] || refuse "HEAD is $head, not $want; check out that commit first"
git merge-base --is-ancestor "$want" origin/main || refuse "$want is not an ancestor of origin/main"
[ -z "$(git status --porcelain)" ] || refuse "the working tree is not clean"

: "${CF_AWS_PROFILE:?set CF_AWS_PROFILE to your AWS profile name}"
: "${CF_ALERT_EMAIL:?set CF_ALERT_EMAIL to the alert address}"
: "${CF_CLAIM_REPOS:?set CF_CLAIM_REPOS to owner/repo[,owner/repo]}"
export AWS_PROFILE="$CF_AWS_PROFILE"

account="$(aws sts get-caller-identity --query Account --output text)"
[ "$account" = "$expected_account" ] || refuse "AWS account is $account, expected $expected_account"
echo "deploying $want to account $account"

"$here/build.sh"

cd "$here"
repos_hcl="[$(printf '"%s",' ${CF_CLAIM_REPOS//,/ } | sed 's/,$//')]"
vars=(-var "aws_profile=$CF_AWS_PROFILE" -var "alert_email=$CF_ALERT_EMAIL" -var "claim_repos=$repos_hcl")
terraform init -input=false
terraform plan -input=false "${vars[@]}" -out=tfplan

bad=$(terraform show -json tfplan | jq -r '.resource_changes[] | select(.type=="aws_lambda_function" or .type=="aws_lambda_function_url") | select(.change.actions | index("delete")) | .address')
if [ -n "$bad" ]; then
  rm -f tfplan
  refuse "the plan would replace or destroy: $bad"
fi

terraform apply -input=false tfplan
rm -f tfplan
echo "deployed $want"
