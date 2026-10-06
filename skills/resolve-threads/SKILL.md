---
name: cf:resolve-threads
description: Resolves every unresolved review thread on a pull request. Each thread is evaluated by its own background agent inside an isolated git worktree, knowing the other threads in the run and the earlier fixes on its file, then fixed (with every sibling instance of the same bug class), dismissed with a recorded rationale, or deferred to a human. When a reviewer's feedback recurs on a file already fixed in an earlier round, a root-cause pass fixes a small cause in one commit or starts cf:plan for a large one. Runs straight through by default; --signoff pauses for approval before anything reaches GitHub.
---

# CF Resolve Threads

Trigger: `/cf:resolve-threads <PR> [--signoff]`.

Question: given everything this thread's author could see plus everything the
repository as a whole can add, is the recommendation worth acting on? A
reviewer's comment and a bot's comment get the same weight; what decides the
verdict is whether the concern holds up once a real agent reads the full
change and the surrounding code, not who raised it.

## Reference files

- `reference/workflow.js`: the Workflow script for step 3. Read it, then pass
  its full contents verbatim as `Workflow`'s `script` argument.
- `reference/replying.md`: verdict bars, reply-style rules and reply
  contracts for step 6. Read it before replying to or resolving any thread.

## Scope

A PR URL, `owner/repo#123`, a bare `#123` (current repo when owner/repo is
omitted), or the PR associated with the current branch. This skill only
operates on pull requests; it has nothing to resolve without one. If no PR
can be resolved unambiguously, ask which one is meant.

## Sign-off

Runs straight through by default: report, commit, reply, resolve, push.
`--signoff` pauses after the step-4 report and asks before replying,
resolving, or pushing. A literal `full auto` or `auto` as the first or last
word of the args is stripped before parsing, with a one-line note that full
auto is already the default. Under away mode `--signoff` is ignored and the
run reports that it assumed the default.

## Workflow

1. **Resolve the PR and its history.** `gh pr view <n> --json
   number,title,body,headRefName,url` for the PR itself. Then run
   `ruby ~/.claude/cf/bin/thread_history.rb <owner>/<repo>#<n>` and keep its
   stdout: `threads` (unresolved), `deferred` (threads already handed to a
   plan, skipped until a reviewer comments again), `priorThreads` (earlier
   threads we fixed, with their `Fixed in` sha), `rounds`, and
   `recurrence`. Every thread entry carries the same identity:
   `threadId` (GraphQL node id, for the resolve mutation), `commentId` (the
   opening comment's integer id, the REST reply target), `path`,
   `reviewer`, `reviewId`, `reviewedCommit` and `openedAt`; open threads
   add `line`, `title` and `comments`. Select recurring threads by
   `recurrence.threadIds`, never by path. GitHub is the source of truth
   for history; do not keep a local count. The script follows every page;
   `truncated` is true only when some history is still unread (past its
   page cap, or a thread or review with more than 100 comments). Then the thread list and the
   recurrence are not the whole story: report `truncated` and stop without
   replying or resolving. If `threads` is empty, report that (and any
   `deferred`) and stop.
2. **Get a real local checkout.** Fetch and check out the PR's head branch
   (not a detached `pull/<N>/head`, since fixes need to be committed and
   pushed on it) so `repoPath` is this checkout's absolute path and `headSha`
   is its current tip.
3. **Run the resolution workflow.** Read `reference/workflow.js` and call
   `Workflow` with its full contents as `script` and `args: { threads,
   priorThreads, recurrence, repoPath, headSha, prNumber, prTitle, prBody }`.
   Invoking this skill is what authorizes the `Workflow` call. The script
   evaluates every thread concurrently, each in its own throwaway
   `git worktree` of `repoPath` at `headSha` so one thread's exploration
   cannot see or collide with another's. When `recurrence.fired` or a
   verdict names an earlier fix, a Root cause phase groups the recurring
   threads by shared cause and sizes each cluster `in_run` (one systemic
   commit) or `plan` (a redesign for cf:plan). It then applies every
   accepted fix sequentially against the live `repoPath` so drift between
   fixes is caught as it happens rather than silently overwritten. It
   returns `{ fixed, wontFix, needsHuman, conflicts, clusters, planClusters,
   plan, recurrence }`. On a repeat run against the same PR, pass back the
   `scriptPath` the first call returned instead of resending `script`.
4. **Report.** For every thread: its verdict, one-line rationale, and (for
   `fixed`) which commit. For every cluster: its `concernClass`,
   `rootCause`, size, and commit or plan slug. Say whether
   `recurrence.fired`. Continue without asking, unless `--signoff` was
   passed; then ask before replying, resolving, or pushing.
5. **Commit.** The Workflow's Apply phase has already committed: one commit
   per in-run cluster and one per unclustered `fixed` thread. An in-run
   cluster with `applied: false` and every `conflicts` entry fold into
   `needsHuman` for reporting and replies.
6. **Reply and resolve.** Before this step, read `reference/replying.md`
   for the verdict bars and reply-style rules. Use the `gh` CLI via Bash by
   default. For `fixed` and `wontFix`: reply to the thread's opening
   comment (`commentId`; GitHub accepts only a top-level comment here, never
   a reply) with `gh api repos/<owner>/<repo>/pulls/<n>/comments/
   <commentId>/replies -f body=...` stating what happened (the commit, or
   the dismissal rationale), then resolve the thread with `gh api graphql
   -f query='mutation { resolveReviewThread(input: {threadId: "<threadId>"})
   { thread { id } } }'`. An MCP-style `add_reply_to_pull_request_comment`
   and `resolve_review_thread` (with the `threadId`) is an acceptable
   alternative when such tools happen to be configured. For `needsHuman` and
   `conflicts`: reply with the open question or the drift that needs a human
   look, and leave the thread unresolved. For an in-run cluster, reply on
   every cluster thread with `Fixed in <commitSha>. <cluster reply>` and
   resolve each. For `planClusters`, reply on every thread with `Deferred to
   plan <plan.slug>. <rootCause>` and leave them unresolved. Reply text
   follows `reference/replying.md`'s reply contracts exactly.
7. **Push.** Push the branch carrying the new commits. The session's active
   cf merge mode (see `cf`) governs whether that push, and any PR update,
   actually happens versus staying local. Skipped when nested (see Nested
   runs).
8. **Start the plan.** Only when the Workflow returned a non-null `plan`
   and the run is not nested. Under away mode, do not start it: pipe
   `plan.seededGoal` to `ruby ~/.claude/cf/bin/ctx_store.rb capture --name
   plan-pending-<plan.slug> --class active --desc "Root-cause plan pending
   for PR #<n>"` and report that the user should run `/cf:active` then
   `/cf:plan <seeded goal>`. Otherwise invoke the `cf:plan` skill with the
   Skill tool, args `<plan.seededGoal> --area <repo basename>`. This is
   the one point where the default run brings questions to the user: the
   interview is the response to feedback that keeps recurring, not a
   sign-off. cf:plan ends at its own handoff prompt.

## Nested runs

When the invocation says `nested under cf:drive`, run straight through
whatever the flags say, do not push (the caller owns the push), do not
start cf:plan, and end the final message with one fenced `json` block the
caller reads:

    {"fixed": 0, "wontFix": 0, "needsHuman": 0, "conflicts": 0,
     "deferred": 0, "clusters": 0, "recurrence": false, "plan": null,
     "truncated": false}

`truncated` is step 1's flag; when true the run stopped there and the
counts are all zero.

`deferred` counts threads this run deferred to a plan, i.e. replied
`Deferred to plan <slug>.` (see step 1's `deferred` field and
`reference/replying.md`).

`plan` is the Workflow's `plan` object (`slug`, `seededGoal`, `threadIds`)
or `null`. Replies and resolutions still happen in a nested run.
