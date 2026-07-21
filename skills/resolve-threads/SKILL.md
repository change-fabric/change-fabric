---
name: pst:resolve-threads
description: Resolves every unresolved review thread on a pull request. Each thread is evaluated by its own background agent inside an isolated git worktree, weighing the comment against the full pull request and repository context, then either implementing the fix directly, dismissing it with a recorded rationale, or deferring it to a human when the call is ambiguous. Verdicts are reported before any code, reply, or resolution reaches GitHub.
---

# PST Resolve Threads

Trigger: `/pst:resolve-threads <PR>`.

Question: given everything this thread's author could see plus everything the
repository as a whole can add, is the recommendation worth acting on? A
reviewer's comment and a bot's comment get the same weight; what decides the
verdict is whether the concern holds up once a real agent reads the full
change and the surrounding code, not who raised it.

## Reference files

- `reference/workflow.js`: the Workflow script for step 3. Read it, then pass
  its full contents verbatim as `Workflow`'s `script` argument.
- `reference/replying.md`: verdict bars and reply-style rules for step 6.
  Read it before replying to or resolving any thread.

## Scope

A PR URL, `owner/repo#123`, a bare `#123` (current repo when owner/repo is
omitted), or the PR associated with the current branch. This skill only
operates on pull requests; it has nothing to resolve without one. If no PR
can be resolved unambiguously, ask which one is meant.

## Workflow

1. **Resolve the PR and its threads.** Use the `gh` CLI via Bash by default,
   since no GitHub MCP server is assumed to be configured:
   `gh pr view <n> --json ...` for `get`, `gh pr diff <n>` for `get_diff`
   (falling back to fetching the PR head locally and diffing with plain
   `git diff`/`git show` if `gh pr diff` fails on a very large PR with HTTP
   406), `gh pr view <n> --json files` for `get_files`, and `gh api graphql`
   for `get_review_comments` since resolving a thread later needs its
   GraphQL node id (a REST-only call like `gh api repos/<owner>/<repo>/
   pulls/<n>/comments --paginate` does not carry that id). An MCP-style
   `pull_request_read` tool with `get`/`get_diff`/`get_files`/
   `get_review_comments` is an acceptable alternative when one happens to be
   configured, but `gh` is the default. Keep only threads where `isResolved`
   is false. For each,
   collect `threadId` (the GraphQL node id, for resolving), the anchor
   `path`/`line`, every comment in the thread in order (author, body), and
   whether the thread is outdated (its anchor line may no longer exist in the
   current diff, so the evaluating agent reads the live file, not the stale
   hunk). If none are unresolved, report that and stop.
2. **Get a real local checkout.** Fetch and check out the PR's head branch
   (not a detached `pull/<N>/head`, since fixes need to be committed and
   pushed on it) so `repoPath` is this checkout's absolute path and `headSha`
   is its current tip.
3. **Run the resolution workflow.** Read `reference/workflow.js` and call
   `Workflow` with its full contents as `script` and `args: { threads,
   repoPath, headSha, prNumber, prTitle, prBody }`. Invoking this skill is
   what authorizes the `Workflow` call. The script evaluates every thread
   concurrently, each in its own throwaway `git worktree` of `repoPath` at
   `headSha` so one thread's exploration cannot see or collide with
   another's, then applies every accepted fix sequentially against the live
   `repoPath` so drift between fixes is caught as it happens rather than
   silently overwritten. It returns `{ fixed, wontFix, needsHuman,
   conflicts }`. On a repeat run against the same PR, pass back the
   `scriptPath` the first call returned instead of resending `script`.
4. **Report before touching GitHub.** For every thread: verdict, one-line
   rationale, and (for `fixed`) which commit. Ask before replying, resolving,
   or pushing, unless the invocation said to proceed automatically.
5. **Commit.** One commit per `fixed` thread, message referencing the
   thread's file and the concern it addressed. `conflicts` (a fix whose diff
   no longer applied cleanly once earlier fixes landed) get no commit and
   fold into `needsHuman` for reporting and replies.
6. **Reply and resolve.** Before this step, read `reference/replying.md`
   for the verdict bars and reply-style rules. Use the `gh` CLI via Bash by
   default. For `fixed` and `wontFix`: reply on the thread's
   last comment with `gh api repos/<owner>/<repo>/pulls/<n>/comments/
   <comment_id>/replies -f body=...` stating what happened (the commit, or
   the dismissal rationale), then resolve the thread with `gh api graphql
   -f query='mutation { resolveReviewThread(input: {threadId: "<threadId>"})
   { thread { id } } }'`. An MCP-style `add_reply_to_pull_request_comment`
   and `resolve_review_thread` (with the `threadId`) is an acceptable
   alternative when such tools happen to be configured. For `needsHuman` and
   `conflicts`: reply with the open question or the drift that needs a human
   look, and leave the thread unresolved.
7. **Push.** Push the branch carrying the new commits. The session's active
   pst merge mode (see `pst`) governs whether that push, and any PR update,
   actually happens versus staying local.
