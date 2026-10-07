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
   plan, skipped until the thread's reviewer comments after the deferral),
   `priorThreads` (earlier threads we fixed, with their `Fixed in` sha),
   `rounds`, and `recurrence`. Every thread entry carries the same identity:
   `threadId` (GraphQL node id, for the resolve mutation), `commentId` (the
   opening comment's integer id, the REST reply target), `path`,
   `reviewer`, `reviewId`, `reviewedCommit` and `openedAt`; open threads
   add `line`, `title` and `comments`. Select recurring threads by
   `recurrence.threadIds`, never by path. GitHub is the source of truth
   for history; do not keep a local count. The script follows every page;
   `truncated` is true only when some history is still unread (past its
   page cap, or a thread or review with more than 100 comments). Then the thread list and the
   recurrence are not the whole story: report `truncated` and stop without
   replying or resolving [RT-5]. If `threads` is empty, report that (and any
   `deferred`) and stop.
2. **Get a real local checkout.** Fetch and check out the PR's head branch
   (not a detached `pull/<N>/head`, since fixes need to be committed and
   pushed on it [RT-1]) so `repoPath` is this checkout's absolute path and
   `headSha` is its current tip.
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
   passed; then ask before replying, resolving, or pushing [RT-1][RT-2][RT-3].
5. **Commit.** The Workflow's Apply phase has already committed: one commit
   per in-run cluster and one per unclustered `fixed` thread. `clusters`
   holds only clusters whose commit landed; a cluster that did not land
   returns its threads in `conflicts`, and every `conflicts` entry folds
   into `needsHuman` for reporting and replies.
6. **Settle the plan, then reply and resolve [RT-2][RT-3][RT-4].** When the Workflow
   returned a non-null `plan`, settle it before any reply names it: run
   `ruby ~/.claude/cf/bin/plan_paths.rb resolve --slug <plan.slug> --area
   <repo basename>`, and when `plan_dir_exists` is true take its
   `suggested_slug` as `plan.slug` and rewrite the seeded goal's closing
   `Use slug <old>.` to match, so cf:plan finds a free directory and never
   picks a different name than the replies carry. Then, in every mode, pipe
   `plan.seededGoal` to `ruby ~/.claude/cf/bin/ctx_store.rb capture --name
   plan-pending-<plan.slug> --class active --desc "Root-cause plan pending
   for PR #<n>"`, so a deferral is never left without a record when the
   interview is abandoned or never starts. Every later use (the deferral
   replies, step 8, the nested block) reads this settled `plan`. Before
   replying, read `reference/replying.md` for the verdict bars and
   reply-style rules. Use the `gh` CLI via Bash by
   default. Commit-citing mutations wait for the push [RT-6]: every
   `Fixed in <sha>` reply and resolution, per thread or cluster, is held
   until the commit it cites is pushed, so no thread is marked settled
   against a commit GitHub cannot reach. Standalone, step 7 posts them once
   its push lands; nested, they go into the summary block's
   `pendingReplies` for the caller to post after its own push. Replies that
   cite no commit (`wontFix`, `needsHuman`, `conflicts`, deferrals) post
   here as usual. For `fixed` and `wontFix`: reply to the thread's opening
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
7. **Test, then push [RT-1].** Standalone (not nested), after the Apply phase has
   committed, run the repo's own test command against `repoPath`: the
   command CLAUDE.md states, else `rake test` when a Rakefile is present,
   else `package.json`'s `scripts.test`, in that order; if none is found,
   do not push and report that no test command could be found. Red means no
   push; report the failure and stop before the push, leaving the
   commits local. Only on green does the branch carrying the new commits
   get pushed. The Workflow script has no tool access and cannot run git
   itself, so the Apply agent's reported `commitSha` is unverified prose
   until checked here: once the push lands, verify each `fixed` and
   cluster thread's `commitSha` with `git merge-base --is-ancestor <sha>
   HEAD` against the pushed branch before posting anything [RT-6]. Only a
   thread whose sha passes that check gets its `Fixed in <sha>` reply and
   resolution; a thread whose sha fails it (not an ancestor, or the
   command errors, for example a malformed or unknown sha) is routed to
   `conflicts` instead, reported, and left open rather than resolved.
   When the push is withheld for any
   reason (red, no test command, or a merge mode that keeps work local),
   reply on those threads instead that the fix is committed locally but
   unpushed, and leave them unresolved. The session's active cf merge mode (see `cf`) governs whether
   that push, and any PR update, actually happens versus staying local.
   Skipped when nested (see Nested runs); the caller owns the push and its
   own test gate.
8. **Start the plan.** Only when the Workflow returned a non-null `plan`
   and the run is not nested. Under away mode, do not start it: step 6's
   `plan-pending-<plan.slug>` pointer already holds the seeded goal, so
   report that the user should run `/cf:active` then `/cf:plan <seeded
   goal>`. Otherwise invoke the `cf:plan` skill with the Skill tool, args
   `<plan.seededGoal> --area <repo basename>`, and once it has written its
   handoff, run `ruby ~/.claude/cf/bin/ctx_store.rb archive
   plan-pending-<plan.slug>`. This is
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
     "truncated": false, "pendingReplies": []}

`pendingReplies` lists the held commit-citing mutations [RT-6], one
`{"threadId", "commentId", "sha", "body", "resolve": true}` per `fixed` or
cluster thread. The caller posts each reply and resolves the thread only
after the push carrying `sha` lands; when it does not push, it replies that
the fix is committed locally but unpushed and leaves the thread
unresolved.

`truncated` is step 1's flag; when true the run stopped there and the
counts are all zero.

`deferred` counts threads this run deferred to a plan, i.e. replied
`Deferred to plan <slug>.` (see step 1's `deferred` field and
`reference/replying.md`).

`plan` is step 6's settled `plan` object (`slug`, `seededGoal`,
`threadIds`) or `null`; its pending pointer is already recorded.
Replies and resolutions that cite no commit still happen in a nested
run; commit-citing ones are only returned in `pendingReplies`.

## Unattended gates

| ID | Action | Requires | When unmet |
|---|---|---|---|
| RT-1 | Push (standalone) | Repo test command green on `repoPath` after Apply | No push; report the failure, leave commits local |
| RT-2 | Resolve a `fixed` thread | The thread's fix landed in a commit SHA matching 7-40 hex characters | Do not resolve; a missing or malformed sha folds into `conflicts`, not `fixed` |
| RT-3 | Resolve a `wont_fix` thread | None; always allowed, all authors | N/A, always resolves |
| RT-4 | Route recurring candidates to a plan cluster | Root-cause map is non-null and accounts for every candidate | Null map, an unaccounted candidate, or a dissolved/failed systemic fix all route to a plan cluster with a generic seeded goal |
| RT-6 | Post a `Fixed in <sha>` reply or resolve a `fixed`/cluster thread | The commit it cites was pushed (standalone: step 7's push; nested: the caller's push), and `git merge-base --is-ancestor <sha> HEAD` against the pushed branch confirms the sha actually landed | Hold it; if no push happens, reply that the fix is committed locally but unpushed and leave the thread unresolved; if the push happened but the ancestor check fails, route to `conflicts` and leave the thread open |
| RT-5 | Any reply, resolution, or push | `Workflow` returned a usable result, and `thread_history.rb`, `plan_paths.rb`, and `ctx_store.rb` all succeeded | Stop; no reply, resolution, or push |

## Failure modes

- The Workflow call errors, or returns nothing usable: stop [RT-5]. Make no
  reply, no resolution, and no push. Nested, emit the fenced json block with
  `"error": true` added so the caller (cf:drive) also stops instead of
  reading zero counts as a clean run.
- `thread_history.rb` exits non-zero, or its stdout does not parse as the
  expected JSON: stop before step 2 [RT-5]. Report the raw output; make no
  reply, resolution, or push.
- `plan_paths.rb resolve` or `ctx_store.rb capture` fails: stop before any
  `Deferred to plan` reply [RT-4][RT-5]. A reply that names a plan slug must
  never be sent while the slug is unsettled or the pending record unwritten.
- A `wont_fix` verdict is resolved unattended for every author, reviewer or
  bot alike; this is the accepted default, not a gap [RT-3] (see step 6).
