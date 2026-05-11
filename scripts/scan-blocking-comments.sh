#!/usr/bin/env bash
# scan-blocking-comments.sh
# Usage: scan-blocking-comments.sh <owner> <repo> <pr_number>
#
# Scans recent issue comments on a PR for known merge-blocking automation
# sentinels. Prints a machine-readable result and exits with:
#   0  - no blocking sentinel found (safe to proceed)
#   1  - blocking sentinel found and NOT already satisfied (merge is blocked)
#   2  - blocking sentinel found but already satisfied on the current branch
#
# Stdout (last line): JSON object
#   { "status": "none" | "blocking" | "satisfied",
#     "sentinel": "<matched sentinel or null>",
#     "ticket_key": "<extracted ticket key or null>",
#     "spec_path_pattern": "<expected path pattern or null>",
#     "comment_url": "<html_url of the triggering comment or null>" }
set -euo pipefail

OWNER="${1:?Usage: $0 <owner> <repo> <pr_number>}"
REPO="${2:?}"
PR_NUMBER="${3:?}"

result_status="none"
result_sentinel=null
result_ticket=null
result_spec_pattern=null
result_comment_url=null

# Fetch all issue comments (paginated)
COMMENTS=$(gh api "repos/$OWNER/$REPO/issues/$PR_NUMBER/comments" \
  --paginate \
  --jq '.[] | {id, user: .user.login, body, html_url}' 2>/dev/null || echo "")

if [ -z "$COMMENTS" ]; then
  echo '{"status":"none","sentinel":null,"ticket_key":null,"spec_path_pattern":null,"comment_url":null}'
  exit 0
fi

# ------------------------------------------------------------------
# Sentinel: missing-spec-check
# Matches: <!-- missing-spec-check --> or "Missing specification document"
# ------------------------------------------------------------------
SPEC_COMMENT=$(echo "$COMMENTS" | jq -s '[.[] | select(
    (.body | test("<!--\\s*missing-spec-check\\s*-->"; "i")) or
    (.body | test("Missing specification document"; "i"))
  )] | first // empty')

if [ -n "$SPEC_COMMENT" ]; then
  COMMENT_URL=$(echo "$SPEC_COMMENT" | jq -r '.html_url')
  COMMENT_BODY=$(echo "$SPEC_COMMENT" | jq -r '.body')

  # Extract ticket key (e.g. GAI-1234, PROJ-99) from comment body first,
  # then fall back to extracting from the PR's head branch name.
  TICKET_KEY=$(echo "$COMMENT_BODY" | grep -oE '[A-Z]{2,10}-[0-9]+' | head -1 || true)
  if [ -z "$TICKET_KEY" ]; then
    HEAD_BRANCH=$(gh pr view "$PR_NUMBER" --repo "$OWNER/$REPO" --json headRefName --jq .headRefName 2>/dev/null || echo "")
    TICKET_KEY=$(echo "$HEAD_BRANCH" | grep -oE '[A-Z]{2,10}-[0-9]+' | head -1 || true)
  fi

  # Check whether the required spec file already exists on the current branch
  if [ -n "$TICKET_KEY" ]; then
    SPEC_PATTERN="docs/plans/${TICKET_KEY}_*_spec.md"
    if git ls-files --error-unmatch $SPEC_PATTERN >/dev/null 2>&1 || \
       find . -path "./$SPEC_PATTERN" -print -quit 2>/dev/null | grep -q .; then
      result_status="satisfied"
    else
      result_status="blocking"
    fi
    result_spec_pattern="\"$SPEC_PATTERN\""
    result_ticket="\"$TICKET_KEY\""
  else
    # Comment found but couldn't extract a ticket key - treat as blocking
    result_status="blocking"
  fi

  result_sentinel='"missing-spec-check"'
  result_comment_url="\"$COMMENT_URL\""
fi

printf '{"status":"%s","sentinel":%s,"ticket_key":%s,"spec_path_pattern":%s,"comment_url":%s}\n' \
  "$result_status" "$result_sentinel" "$result_ticket" "$result_spec_pattern" "$result_comment_url"

case "$result_status" in
  blocking)  exit 1 ;;
  satisfied) exit 2 ;;
  none)      exit 0 ;;
esac
