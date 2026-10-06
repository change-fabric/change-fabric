# cf:code-review second round

Read this when step 1's `reviewRound.secondRound` is true. It replaces
steps 3 and 4 for that run.

## When it applies

`scripts/thread_history.rb` decides it from GitHub alone, never from a
local ledger. The authenticated GitHub user (`viewer.login`) already posted
a cf:code-review round on this PR (a review carrying at least one comment
whose header the finding renderer produced), the PR head has moved past
that review's commit, and every thread from it is resolved or outdated. If
this run's Workflow still returns findings, the PR is being patched one
comment at a time. More inline comments would continue that, so this round
looks at the architecture instead. A second round whose Workflow returns
no findings posts nothing and reports that.

## Steps

1. **Run the review Workflow as usual** (SKILL.md step 2). Keep `posted`.
2. **Report** `posted` as in step 3, saying this is a second round and
   naming the prior review commit.
3. **Plan.** Under away mode, skip to "Away" below. Otherwise invoke the
   `cf:plan` skill with the Skill tool, args: a seeded goal plus
   `--area <repo basename>`. Each `reviewRound.priorReviews` entry
   carries `{id, databaseId, reviewer, commit, submittedAt, titles}`:
   take the first round's finding titles from `titles`, with no further
   API call. `id` is the GraphQL node id; a REST route under
   `pulls/<n>/reviews/<review_id>` takes the integer `databaseId`, never
   `id`.
   The seeded goal is plain prose:
   "Second-round review of PR #<n> (<title>) in <owner>/<repo>. The first
   round's findings (<titles>) were addressed, and this round found
   <tier title path:line, ...>. Findings keep landing on <paths>. Plan a
   comprehensive recommendation of a different architecture or strategy
   for the problem this PR is solving, written for the PR's author, not a
   patch list. Use slug pr-<n>-review-round." The cf:plan interview reaches
   the user; that is intended.
4. **Render.** When cf:plan has landed its set, read its `goal.md` and the
   phase titles in its `plan.md`. Build the renderer input:
   - `title`: the recommendation in under 60 characters;
   - `summary`: the core of `goal.md` (what the PR solves and the
     recommended architecture or strategy), at most about 450 characters
     after your own trimming, so the renderer's truncation is a safety net;
   - `folded`: `{tier, title}` for every P2 and P3 in `posted`;
   - `handoff`: a self-contained prompt for an agent working on the PR's
     branch: the PR number and repo, the recommended direction, the plan's
     phases as numbered steps, and "do not patch the individual findings;
     restructure per this direction". It must name no local path (no
     plans tree, no home directory, no absolute path such as a checkout
     or temp directory); the renderer refuses one.
   Pipe it as JSON to `ruby ~/.claude/cf/bin/render_round_review.rb` and
   use its stdout verbatim as the review body. Apply `cf:ai-slop`'s rules
   to every field first.
5. **Post** one review: `gh api repos/<owner>/<repo>/pulls/<n>/reviews
   --method POST --input review.json`, where `review.json` carries
   `"event": "COMMENT"`, `body` is the rendered text, and `comments` holds
   only the P1 entries of `posted`, each rendered by
   `render_finding_comment.rb` as usual. Keep `event` inside the JSON: with
   `--input`, `gh api` sends any `-f` field as a URL query parameter, and a
   review with no `event` in its body stays pending.
   Never `REQUEST_CHANGES` or `APPROVE`. Under `--signoff`, show the body
   and the P1 list and ask before posting. Merge mode does not gate it.
6. **Report** the review URL, the plan directory, and cf:plan's handoff.

## Away

No interview under away mode. Skip the post entirely when `posted` has no
P1 finding: GitHub rejects a `"event": "COMMENT"` review with no body and
no comments. Otherwise post the P1 findings inline (one review whose
`review.json` carries `"event": "COMMENT"` and no body), hold the P2 and
P3 findings, pipe the seeded goal plus the held findings to `ruby ~/.claude/cf/bin/ctx_store.rb
capture --name plan-pending-pr-<n>-review-round --class active --desc
"Second-round review plan pending for PR #<n>"`, and report that the user
should run `/cf:active` then `/cf:plan <seeded goal>`.
