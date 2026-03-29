---
name: pst:resolve-threads
description: Address every unresolved PR conversation - test fixes in worktrees, apply proven ones, reply with reasoning, resolve threads, dismiss change requests, and re-request review from human reviewers.
argument-hint: "[PR-number | PR-URL] [--dry-run]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, AskUserQuestion
---

# Resolve PR Threads

Fetch every unresolved conversation and comment on a GitHub pull request, classify each one, and systematically address them. For actionable suggestions: test a fix in an isolated worktree, and if it passes quality gates, squash-merge it into the branch and reply confirming the fix. For suggestions that are not applicable: reply with clear reasoning. Resolve all threads, dismiss any outstanding change-request reviews, and re-request review from all human reviewers so they can take a fresh look.

---

## Input Parsing

<arguments> #$ARGUMENTS </arguments>

**Parse arguments:**

- PR number (e.g., `42`)
- PR URL (e.g., `https://github.com/{owner}/{repo}/pull/{N}`)
- `--dry-run` -- analyze and classify conversations, show what would be done, but do not push, reply, or resolve anything
- No arguments -- detect PR from current branch via `gh pr view`

---

## Phase 1 -- Guards & Context

```bash
BRANCH=$(git branch --show-current 2>/dev/null)
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
```

| Condition | Action |
|---|---|
| `$BRANCH` is empty | Stop: "Not on a branch." |
| `gh` not available | Stop: "GitHub CLI (gh) is required." |
| No PR found for args | Stop: "No open PR found. Provide a PR number or URL." |

**Resolve PR metadata:**

```bash
PR_JSON=$(gh pr view $N --json number,url,title,body,headRefName,headRefOid,baseRefName)
PR_NUMBER=$(echo "$PR_JSON" | jq -r .number)
PR_URL=$(echo "$PR_JSON" | jq -r .url)
HEAD_BRANCH=$(echo "$PR_JSON" | jq -r .headRefName)
HEAD_SHA=$(echo "$PR_JSON" | jq -r .headRefOid)
OWNER_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
OWNER=$(echo "$OWNER_REPO" | cut -d/ -f1)
REPO=$(echo "$OWNER_REPO" | cut -d/ -f2)
```

**Ensure working tree is on the PR branch and clean:**

If current branch does not match `$HEAD_BRANCH` or working tree is dirty, warn and stop: "Check out branch `$HEAD_BRANCH` with a clean working tree before running this skill."

---

## Phase 2 -- Fetch All Conversations

Gather every unresolved conversation from the PR. There are three distinct sources that must all be queried.

### 2a. Review threads (inline code comments)

These are comments attached to specific lines in specific files, typically nested under a review.

```bash
gh api graphql -f query='
{
  repository(owner: "'$OWNER'", name: "'$REPO'") {
    pullRequest(number: '$PR_NUMBER') {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          startLine
          diffSide
          comments(first: 50) {
            nodes {
              id
              databaseId
              author { login }
              body
              createdAt
              path
              line
              startLine
            }
          }
        }
      }
    }
  }
}'
```

Filter to `isResolved == false`. Each thread has one or more comments -- the first comment is the original feedback, subsequent comments are replies.

### 2b. Issue comments (top-level PR comments)

These appear on the "Conversation" tab, not attached to any code line.

```bash
gh api repos/$OWNER/$REPO/issues/$PR_NUMBER/comments --paginate
```

These are flat comments, not threaded. Each has `id`, `user.login`, `body`, `created_at`.

### 2c. PR review bodies

Reviews themselves can have a top-level body (the summary the reviewer writes when submitting a review).

```bash
gh api repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews --paginate
```

Each review has `id`, `user.login`, `body`, `state` (APPROVED, CHANGES_REQUESTED, COMMENTED, etc.). The body may be empty or may contain a summary.

---

## Phase 3 -- Classify Conversations

For every item collected in Phase 2, classify it into one of these categories:

### Classification categories

| Category | Description | Examples |
|---|---|---|
| `bot` | Automated CI/deploy comment | Vercel preview, Netlify deploy, Codecov, GitHub Actions bot, Dependabot |
| `review-summary-redundant` | A review body that only restates what the reviewer's inline comments already say | Reviewer submits a review with body "Please fix the null check on line 42 and rename the variable" when those exact things are already inline comments in the same review |
| `review-summary-unique` | A review body with substantive feedback not covered by inline comments | Architectural concerns, cross-cutting suggestions, questions about approach |
| `inline-feedback` | An unresolved inline code comment with actionable feedback | "This should handle the null case", "Consider using a Map here" |
| `inline-question` | An inline comment that asks a question rather than suggesting a change | "Why was this approach chosen?", "Is this intentional?" |
| `top-level-feedback` | A top-level issue comment with actionable feedback | Suggestions, concerns, requests for changes |
| `top-level-question` | A top-level comment asking a question | "What's the migration plan?", "Have you considered X?" |
| `noise` | Reaction-only, emoji-only, "+1", "LGTM", or otherwise non-actionable | |

### Classification rules

**Bot detection:** Match `author.login` against known bot patterns:

- Exact matches: `vercel[bot]`, `netlify[bot]`, `codecov[bot]`, `dependabot[bot]`, `github-actions[bot]`, `renovate[bot]`, `linear[bot]`, `changeset-bot[bot]`
- Pattern: login ends with `[bot]` or `bot`
- Heuristic: body contains deployment URLs, coverage reports, or CI status badges with no human-written prose

**Redundancy detection for review summaries:** When a review has both a body and inline comments:

1. Extract the key assertions/requests from the review body
2. Extract the key assertions/requests from each inline comment in that same review
3. If every assertion in the body is a restatement of an inline comment (same file, same concern), classify as `review-summary-redundant`
4. If the body contains any assertion NOT covered by an inline comment, classify as `review-summary-unique`

**Inline vs top-level:** Determined by source (2a = inline, 2b = top-level, 2c = review summary).

**Feedback vs question:** If the comment primarily asks a question (ends with `?`, starts with "why", "how", "what", "is this", "have you", "should we"), classify as question. If it suggests a specific change or flags a specific problem, classify as feedback.

### Build the work queue

After classification, build an ordered work queue:

1. **Skip entirely:** `bot`, `noise`, `review-summary-redundant`
2. **Process:** `inline-feedback`, `review-summary-unique`, `top-level-feedback`, `inline-question`, `top-level-question`

Sort by priority: `inline-feedback` first (most concrete and actionable), then `review-summary-unique`, then `top-level-feedback`, then questions.

**Log classification summary:**

```
--- THREAD CLASSIFICATION ---
Total conversations: {N}
  Bot/CI:         {N} (skipped)
  Noise:          {N} (skipped)
  Redundant:      {N} (skipped)
  Inline feedback: {N}
  Inline question: {N}
  Review summary:  {N} (unique)
  Top-level:       {N}
Work queue:        {N} items
--- END CLASSIFICATION ---
```

**If `--dry-run`:** Print the classification summary and the full work queue with details, then stop.

---

## Phase 4 -- Deduplicate

Before processing, deduplicate the work queue to avoid testing the same fix twice:

1. **Group inline comments by file + concern:** If two inline comments on the same file address the same underlying issue (e.g., "handle null" on line 10 and "add null check" on line 12 of the same function), merge them into a single work item. The response will reference both threads.

2. **Cross-reference review summaries against inline comments already in the queue:** If a `review-summary-unique` item's novel content is already captured by an inline comment in the queue, drop it and note the mapping.

3. **Merge top-level feedback with inline feedback:** If a top-level comment says "fix the error handling in auth.ts" and there is already an inline comment on auth.ts about error handling, merge them.

Log any deduplication:

```
Deduplicated: {N} items merged, {N} remain in work queue
```

---

## Phase 5 -- Process Each Work Item

For each item in the deduplicated work queue, attempt to address it.

### 5a. For feedback items (inline-feedback, review-summary-unique, top-level-feedback)

**Spawn a sub-agent per item for parallel processing:**

```
Agent:
  description: "Address feedback: {short summary}"
  isolation: worktree
  run_in_background: true
```

**Sub-agent workflow:**

1. **Understand the feedback:** Read the comment, the referenced file(s) and surrounding context. If inline, read the specific lines and the full function/component they belong to.

2. **Assess relevance:** Determine if the suggestion is:
   - **Applicable and correct** -- the suggestion would improve the code
   - **Already addressed** -- the code already handles what the reviewer is concerned about (they may have missed it)
   - **Not applicable** -- the suggestion conflicts with project conventions, architecture decisions, or would introduce regressions
   - **Out of scope** -- valid concern but belongs in a separate PR/ticket

3. **If applicable: attempt the fix.**
   - Apply the minimum edit that addresses the feedback
   - Do not refactor beyond what was requested
   - Do not change unrelated code
   - Run quality gates:
     ```bash
     # Detect package manager
     if [ -f pnpm-lock.yaml ]; then PKG="pnpm"
     elif [ -f yarn.lock ]; then PKG="yarn"
     else PKG="npm"; fi

     $PKG run build 2>&1
     $PKG run lint 2>&1
     $PKG run typecheck 2>&1
     $PKG run test 2>&1
     ```
   - If all gates pass: verdict is `FIXED`
   - If any gate fails: attempt to fix the gate failure (one retry). If still failing, verdict is `NOT_FIXABLE` with reason.

4. **If not applicable:** Prepare a clear explanation (2-3 sentences) of why, referencing specific code, conventions, or architectural decisions.

5. **Return result:**
   - Verdict: `FIXED` | `ALREADY_ADDRESSED` | `NOT_APPLICABLE` | `OUT_OF_SCOPE` | `NOT_FIXABLE`
   - If `FIXED`: the diff (files changed, specific edits made)
   - If not `FIXED`: the reasoning

### 5b. For question items (inline-question, top-level-question)

Do NOT use worktree isolation for questions. Instead:

1. Read the relevant code context
2. Formulate a clear, concise answer (2-4 sentences)
3. Reference specific lines, functions, or architectural decisions that answer the question
4. Verdict: `ANSWERED`

---

## Phase 6 -- Apply Fixes

After all sub-agents complete, collect results and apply proven fixes to the working branch.

### 6a. Collect FIXED items

Gather all items with verdict `FIXED`. For each, the sub-agent produced a diff.

### 6b. Apply fixes sequentially

For each `FIXED` item, apply the edit to the working tree. If two fixes touch the same file, apply them carefully to avoid conflicts. If a conflict arises, attempt to merge; if that fails, keep the first fix and downgrade the second to `NOT_FIXABLE` with reason "conflicts with another fix."

### 6c. Run quality gates on combined fixes

After all fixes are applied, run the full quality gate suite one final time on the combined result:

```bash
$PKG run build 2>&1
$PKG run lint 2>&1
$PKG run typecheck 2>&1
$PKG run test 2>&1
```

If the combined result fails a gate that individual fixes passed:

1. Identify which fix(es) caused the regression by bisecting (remove fixes one at a time)
2. Remove the offending fix(es) and downgrade their verdict to `NOT_FIXABLE`
3. Re-run gates to confirm the remaining fixes pass

### 6d. Commit and push

If any fixes survived:

```bash
git add <specific fixed files>
git commit -m "$(cat <<'EOF'
Address PR review feedback

{one-line summary per fix, e.g.:}
- Handle null case in parseConfig (R1)
- Add input validation to submitForm (R3)
- Use Map instead of object for lookup (R5)

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"

git push --force-with-lease origin "$HEAD_BRANCH"
```

Log:

```
Applied {N} fixes, pushed to {HEAD_BRANCH}
```

---

## Phase 7 -- Reply to Conversations

After fixes are pushed (or skipped), reply to every processed conversation.

### Reply format by type

**For inline feedback (FIXED):**

```markdown
Fixed in {commit_short_sha}.

{brief description of what was changed}
```

**For inline feedback (ALREADY_ADDRESSED):**

```markdown
This is already handled -- {explanation referencing specific code}.
```

**For inline feedback (NOT_APPLICABLE / OUT_OF_SCOPE / NOT_FIXABLE):**

```markdown
Not addressing this here -- {reasoning}.
```

**For top-level comments and unique review summaries**, prepend a blockquote of the original comment to make it clear which comment is being addressed:

```markdown
> {exact text of the original comment, truncated to first 3 lines if very long}

{response}
```

If the original comment is very long (more than ~300 chars), truncate with "..." and include enough to be unambiguous.

**For questions (inline or top-level):**

```markdown
{answer to the question, referencing specific code}
```

For top-level questions, also prepend the blockquote.

### Posting replies

**For inline review threads** (from Phase 2a):

Reply to the thread using the review comment reply API:

```bash
gh api repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments \
  --method POST \
  --field body="$REPLY_BODY" \
  --field in_reply_to=$COMMENT_DATABASE_ID
```

Where `$COMMENT_DATABASE_ID` is the `databaseId` of the first comment in the thread.

**For top-level issue comments** (from Phase 2b):

```bash
gh api repos/$OWNER/$REPO/issues/$PR_NUMBER/comments \
  --method POST \
  --field body="$REPLY_BODY"
```

**For unique review summaries** (from Phase 2c):

Reply as a top-level issue comment (there is no API to reply directly to a review body):

```bash
gh api repos/$OWNER/$REPO/issues/$PR_NUMBER/comments \
  --method POST \
  --field body="$REPLY_BODY"
```

---

## Phase 8 -- Resolve Threads

After all replies are posted, resolve every unresolved review thread that was processed.

**Resolve inline review threads:**

```bash
gh api graphql -f query='
mutation {
  resolveReviewThread(input: {threadId: "$THREAD_NODE_ID"}) {
    thread { isResolved }
  }
}'
```

Do this for:
- All `FIXED` threads
- All `ALREADY_ADDRESSED` threads
- All `NOT_APPLICABLE` threads (we replied with reasoning)
- All `OUT_OF_SCOPE` threads (we replied with reasoning)
- All `NOT_FIXABLE` threads (we replied with reasoning)
- All `ANSWERED` threads (question was answered)

**Do NOT resolve:**
- Bot/CI comments (they are not review threads)
- Top-level issue comments (they are not resolvable via the API)

For top-level issue comments that were addressed, the reply itself serves as the resolution.

---

## Phase 9 -- Dismiss Change Requests

After resolving all threads, dismiss any outstanding "changes requested" reviews. The feedback has been addressed (fixed, answered, or replied to with reasoning), so the blocking reviews should be cleared.

**Fetch reviews with CHANGES_REQUESTED state:**

```bash
REVIEWS=$(gh api repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews --paginate \
  | jq '[.[] | select(.state == "CHANGES_REQUESTED")]')
```

**Dismiss each one:**

```bash
for REVIEW_ID in $(echo "$REVIEWS" | jq -r '.[].id'); do
  gh api repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews/$REVIEW_ID/dismissals \
    --method PUT \
    --field message="All review feedback has been addressed. Dismissing to unblock -- re-requesting your review for a fresh look." \
    --field event="DISMISS"
done
```

Log:

```
Dismissed {N} change-request review(s)
```

If no CHANGES_REQUESTED reviews exist, skip silently.

---

## Phase 10 -- Re-request Review from Human Reviewers

Re-request review from any human (non-bot) who previously left a review on this PR, so they are notified that their feedback has been addressed.

**Identify human reviewers:**

1. From the reviews fetched in Phase 2c and Phase 9, collect all unique `user.login` values
2. Filter out bots using the same bot detection rules from Phase 3 (login ends with `[bot]`, known bot names)
3. The remaining logins are human reviewers who should be re-requested

**Re-request review:**

```bash
gh pr edit $PR_NUMBER --add-reviewer "$REVIEWER1,$REVIEWER2,..."
```

If `gh pr edit` fails (e.g., missing `read:org` scope), fall back to the REST API:

```bash
gh api repos/$OWNER/$REPO/pulls/$PR_NUMBER/requested_reviewers \
  --method POST \
  --input - <<EOF
{"reviewers": ["$REVIEWER1", "$REVIEWER2"]}
EOF
```

Log:

```
Re-requested review from: {reviewer1}, {reviewer2}, ...
```

If no human reviewers are found, skip silently.

---

## Output Contract

Always print this block at the end:

```
--- RESOLVE RESULT ---
pr: #{N} ({url})
total-conversations: {N}
skipped-bot: {N}
skipped-noise: {N}
skipped-redundant: {N}
processed: {N}
fixed: {N}
already-addressed: {N}
not-applicable: {N}
out-of-scope: {N}
not-fixable: {N}
answered: {N}
threads-resolved: {N}
reviews-dismissed: {N}
review-re-requested: {reviewer1, reviewer2, ... | none}
commit: {short_sha | none}
pushed: {yes | no}
--- END RESOLVE RESULT ---
```

---

## Error Handling

| Condition | Action |
|---|---|
| 401/403 from GitHub | Stop: instruct `gh auth login` |
| 422 posting reply | Warn, skip that reply, continue with remaining |
| Rate limited (429) | Wait and retry once, then warn and continue |
| No unresolved conversations | Print "No unresolved conversations on PR #{N}." and exit cleanly |
| Sub-agent worktree failure | Skip that item with `NOT_FIXABLE` verdict |
| All sub-agents fail | Post replies without fixes, note "unable to test fixes in isolation" |
| Combined quality gate fails after bisect | Remove all suspect fixes, push only clean ones |
| Push fails | Stop with error, do not post replies (fixes not yet on remote) |
| Dirty working tree | Stop: "Clean your working tree before running this skill." |
| GraphQL resolve fails | Warn per thread, continue resolving others |
