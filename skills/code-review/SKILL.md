---
name: cf:code-review
description: Review a pull request, branch, file set, or feature description for correctness bugs and refactor opportunities. Verifies each candidate finding in an isolated worktree before posting only the ones that survive, so PR feedback is curated instead of noisy.
---

# CF Code Review

Trigger: `/cf:code-review <scope>`.

Question: does this finding survive an isolated attempt to refute it? A
plausible-sounding comment that was never checked against the real code is the
AI slop this skill exists to filter out. Silence beats a wrong or nitpicky
comment; when in doubt, drop it.

## Reference files

- `reference/workflow.js`: the Workflow script for step 2. Read it, then pass
  its full contents verbatim as `Workflow`'s `script` argument.
- `reference/posting.md`: tier bars and comment-rendering rules for step 4.
  Read it before posting any comment.

## Scope

Accepted forms, resolved in this order:

1. A PR URL or `owner/repo#123` / bare `#123` (current repo when owner/repo is
   omitted). Resolve with the `gh` CLI via Bash (e.g. `gh pr view <n> --json
   ...`), the default and reliable path since no GitHub MCP server is assumed
   to be configured; fall back to an MCP-style `pull_request_read` tool only
   if one happens to be available.
2. A branch or ref: diff against the default branch.
3. An explicit file list or glob.
4. A semantic description of a feature ("the auth refactor", "the caching
   layer"): locate the files with Explore/Grep, list what was found, and
   confirm the set before reviewing.
5. The whole repository: only on explicit request. State the file count
   before proceeding, given the cost; the workflow in step 2 shards it
   automatically once that count crosses its threshold.

If scope is ambiguous, ask which PR or files are meant. Do not guess.

## Workflow

1. **Resolve scope to files, a repo, and a head commit.** PR: prefer the `gh`
   CLI via Bash as the default method, since no GitHub MCP server is assumed
   to be configured: `gh pr view <n> --json files` for `get_files`, `gh pr
   diff <n>` for `get_diff`, and `gh api repos/<owner>/<repo>/pulls/<n>/
   comments --paginate` for `get_comments`/`get_review_comments`, so ground
   already covered by a human or a prior review is not re-flagged. `gh pr
   diff` can fail on very large PRs (HTTP 406, diff too large); when it
   does, fall back to fetching the PR head locally (`git fetch origin
   pull/<N>/head:pr-<N>`) and diffing locally against the base branch with
   plain `git diff`/`git show`. If the PR's head is not already fetched
   locally, fetch it the same way so it resolves to a real local commit.
   An MCP-style `pull_request_read` tool (`get_diff`/`get_files`/
   `get_comments`/`get_review_comments`) is an acceptable alternative when
   one happens to be configured, but `gh` is the default. Everything else:
   `git diff`, `git show`, or plain reads. Record
   `repoPath` (the local clone's absolute path) and `headSha` (the commit
   whose code is under review, i.e. the PR's head or the branch tip, never
   the merge-base) alongside the file list; step 2 needs a real commit
   worktrees can check out, not a moving branch name.
2. **Run the review workflow.** Read `reference/workflow.js` and call
   `Workflow` with its full contents as `script` and `args: { files,
   repoPath, headSha, cap }` (`cap` optional, defaults to 15). Invoking this
   skill is what authorizes the `Workflow` call, so no separate
   orchestration opt-in is needed. The script shards a large file set into
   semantic sections, finds candidates per shard, verifies every candidate
   by trying to refute it inside its own throwaway `git worktree` of
   `repoPath` at `headSha`, and independently rechecks every P1 before it
   is allowed to keep that tier. It returns `{ shards, posted,
   droppedForVolume }`; `posted` is the deduped, ranked, capped finding
   list. On a repeat run against the same scope, pass the `scriptPath` the
   first call returned instead of resending `script`, so unchanged stages
   replay from cache.

   `repoPath` matters because the `Agent` tool's `isolation: "worktree"`
   option only ever isolates the *session's own primary repository* (where
   the session started), not an arbitrary path named in a script's args;
   passing it something else silently isolates the wrong tree. When
   `repoPath` is that primary repository this is harmless, but it is not
   what makes verification correct, so the script does not rely on it: every
   Verify and Recheck P1 call is told to create and clean up its own `git
   worktree add`/`remove` of `repoPath` explicitly, which works the same way
   whether `repoPath` is the session's own repo or a separate clone.
3. **Report before posting.** This checkpoint is mandatory on every run and
   is reached even when a finding was already fixed locally: applying a fix
   in the working tree never substitutes for the post-to-PR decision. Show
   `posted` (`path:line`, tier, one line each) plus the shard summary and
   `droppedForVolume` count, and ask whether to post. Skip the ask only when
   the invocation said to post automatically. If the `Workflow` call errored
   or returned no `posted` list, say so explicitly and stop here; do not
   silently fall back to hand-applying fixes without surfacing this report.
4. **Post.** Before this step, read `reference/posting.md` for the tier
   bars and comment-rendering rules.
   - PR scope: use the `gh` CLI via Bash by default, submitting the review
     and its comments in one call, e.g. `gh api
     repos/<owner>/<repo>/pulls/<n>/reviews --method POST -f event=COMMENT
     --input review.json`, with a JSON payload built from `posted` (each
     entry anchored to `path`/`line`, body rendered per
     `reference/posting.md`). An MCP-style `pull_request_review_write` with
     `create` (no `event`, so it stays pending), then
     `add_comment_to_pending_review` per finding, then `submit_pending` with
     `event: "COMMENT"`, is an acceptable alternative when such a tool
     happens to be configured. Never `REQUEST_CHANGES` or `APPROVE` unless
     asked. Posting these review
     comments is not a `git push`, a `gh pr merge`, or opening a PR, so the
     cf merge mode does not gate it: post in every mode (Local only
     included) whenever the user approves in step 3. Merge mode restricts
     only landing code, never review commentary on a PR that already
     exists.
   - Non-PR scope: there is nothing to post to. The curated report to the
     user is the deliverable.
