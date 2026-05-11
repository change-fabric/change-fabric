#!/usr/bin/env bash
# watch-post-merge-ci.sh
# Usage: watch-post-merge-ci.sh <owner> <repo> <merge_sha> <base_branch> <pr_files_json>
#
# After a PR is squash-merged:
#   1. Polls for a CI workflow run on base_branch at merge_sha (up to 90s).
#   2. Watches the run to completion if found.
#   3. Spot-checks each file in pr_files_json against the base branch.
#
# Stdout (last line): JSON object
#   {
#     "run_found": true|false,
#     "run_id": <int or null>,
#     "run_conclusion": "success"|"failure"|"cancelled"|"skipped"|null,
#     "spot_checks": [
#       { "file": "path/to/file", "exists": true|false }
#     ],
#     "spot_check_pass": <int>,
#     "spot_check_total": <int>
#   }
#
# Exit codes:
#   0 - run passed (or no run found) and all spot-checks passed
#   1 - run failed or one or more spot-checks failed
set -euo pipefail

OWNER="${1:?Usage: $0 <owner> <repo> <merge_sha> <base_branch> <pr_files_json>}"
REPO="${2:?}"
MERGE_SHA="${3:?}"
BASE_BRANCH="${4:?}"
PR_FILES_JSON="${5:?}"  # JSON array of file path strings, e.g. '["src/a.ts","src/b.ts"]'

MAX_WAIT=90   # seconds to poll for a run to appear
POLL_INTERVAL=10
RUN_ID=""
RUN_CONCLUSION="null"
RUN_FOUND=false

# ---------------------------------------------------------------
# 1. Poll for a workflow run on base_branch at merge_sha
# ---------------------------------------------------------------
elapsed=0
while [ "$elapsed" -lt "$MAX_WAIT" ]; do
  RUN_JSON=$(gh run list \
    --repo "$OWNER/$REPO" \
    --branch "$BASE_BRANCH" \
    --limit 10 \
    --json databaseId,headSha,status,conclusion,name \
    --jq ".[] | select(.headSha == \"$MERGE_SHA\")" 2>/dev/null | head -1 || true)

  if [ -n "$RUN_JSON" ]; then
    RUN_FOUND=true
    RUN_ID=$(echo "$RUN_JSON" | jq -r '.databaseId')
    RUN_STATUS=$(echo "$RUN_JSON" | jq -r '.status')
    RUN_CONCLUSION=$(echo "$RUN_JSON" | jq -r '.conclusion // "null"')
    break
  fi

  sleep "$POLL_INTERVAL"
  elapsed=$((elapsed + POLL_INTERVAL))
done

# ---------------------------------------------------------------
# 2. Watch the run if it's still in-progress
# ---------------------------------------------------------------
if [ "$RUN_FOUND" = "true" ] && [ "$RUN_STATUS" != "completed" ]; then
  if gh run watch "$RUN_ID" \
       --repo "$OWNER/$REPO" \
       --interval 15 2>/dev/null; then
    # Refresh conclusion after watch completes
    RUN_CONCLUSION=$(gh run view "$RUN_ID" \
      --repo "$OWNER/$REPO" \
      --json conclusion \
      --jq '.conclusion // "unknown"' 2>/dev/null || echo "unknown")
  fi
fi

# ---------------------------------------------------------------
# 3. Spot-check each PR file exists on base branch
# ---------------------------------------------------------------
SPOT_CHECKS="[]"
SPOT_PASS=0
SPOT_TOTAL=0

# Parse the pr_files_json array; iterate over each path
FILES=$(echo "$PR_FILES_JSON" | jq -r '.[]' 2>/dev/null || true)
if [ -n "$FILES" ]; then
  while IFS= read -r FILE; do
    [ -z "$FILE" ] && continue
    SPOT_TOTAL=$((SPOT_TOTAL + 1))
    if git cat-file -e "origin/${BASE_BRANCH}:${FILE}" 2>/dev/null; then
      SPOT_PASS=$((SPOT_PASS + 1))
      SPOT_CHECKS=$(echo "$SPOT_CHECKS" | jq ". + [{\"file\": $(echo "$FILE" | jq -R .), \"exists\": true}]")
    else
      SPOT_CHECKS=$(echo "$SPOT_CHECKS" | jq ". + [{\"file\": $(echo "$FILE" | jq -R .), \"exists\": false}]")
    fi
  done <<< "$FILES"
fi

# ---------------------------------------------------------------
# 4. Emit result JSON
# ---------------------------------------------------------------
if [ "$RUN_FOUND" = "true" ]; then
  RUN_ID_JSON="$RUN_ID"
  RUN_FOUND_JSON="true"
else
  RUN_ID_JSON="null"
  RUN_FOUND_JSON="false"
fi

RESULT=$(jq -n \
  --argjson run_found "$RUN_FOUND_JSON" \
  --argjson run_id "$RUN_ID_JSON" \
  --arg run_conclusion "$RUN_CONCLUSION" \
  --argjson spot_checks "$SPOT_CHECKS" \
  --argjson spot_pass "$SPOT_PASS" \
  --argjson spot_total "$SPOT_TOTAL" \
  '{run_found: $run_found, run_id: $run_id, run_conclusion: $run_conclusion,
    spot_checks: $spot_checks, spot_check_pass: $spot_pass, spot_check_total: $spot_total}')

echo "$RESULT"

# Exit 1 if run failed or any spot-check missed
if [ "$RUN_FOUND" = "true" ] && [ "$RUN_CONCLUSION" = "failure" ]; then
  exit 1
fi
if [ "$SPOT_PASS" -lt "$SPOT_TOTAL" ]; then
  exit 1
fi
exit 0
