---
name: cf:sweep
description: Sweeps a repo's open feature pull requests and plans how to land them as a group, covering merge order, trial-merged conflict mitigations, terraform and migration sequencing, and a per-contributor trust policy persisted across runs. Reports only, lands with sign-off, or runs unattended under /loop to keep a development environment current.
---

# CF Sweep

Analyze every open feature pull request in the current repo as one set, then
land them in an order that holds up.

Trigger: `/cf:sweep [report|land|auto]`.

Question: if these PRs merge today, in what order do they land without
breaking trunk, stranding an author in a doomed rebase, or applying a
migration before the infrastructure it needs?

`cf:drive` lands one PR. `cf:sweep` decides which PRs land, in what order, and
what has to happen between them. It delegates the per-PR review, CI, and
approval mechanics to `cf:drive` rather than reimplementing them.

## Reference files

- `reference/workflow.js`: the Workflow script for the whole cross-PR
  analysis (step 4). Read it, then pass its full contents verbatim as
  `Workflow`'s `script` argument.
- `reference/summaries.md`: the sweep summary format, the landing checkpoint
  format, and the author-warning comment format (steps 5, 6, 7). Read before
  composing any of them.

## Scope

The sweep operates on open PRs in the current repo, split by what their base
and head branches are.

**The promotion chain.** A repo's root `CHANGE.md` frontmatter declares
`change_policy.protected_branches`, its trunk-and-environment chain, lowest
first (`[development, staging, production]`, or just `[main]`). See
`skills/change/reference/CHANGE-frontmatter-spec.md` and
`skills/change/reference/CHANGE.template.md`. Read it with
`ruby -e 'require "#{Dir.home}/.claude/cf/bin/change_policy"; puts ChangePolicy.for_repo(Dir.pwd)&.protected_branches'`
rather than parsing the YAML by hand, so the sweep sees the same chain the
merge gate does (including branches named only under `promotion:`).

**Trunk** is the first entry in that chain. With no `CHANGE.md`, or a
`CHANGE.md` with no `change_policy`, trunk is the repo's actual default branch
from `gh repo view --json defaultBranchRef`.

**Release PRs are always out of scope.** A PR whose base AND head are both in
the protected chain is a promotion (base `staging`, head `development`).
Sweeping those means promoting an environment, which is a human decision with
its own gate; this skill never touches them. Under the fallback (no
`CHANGE.md`), apply the same rule against the conventional environment names
`main`, `master`, `development`, `dev`, `staging`, `production`, `prod`: base
and head both in that set means out of scope. State which rule was used in the
report, since a repo with a `development` feature branch and no `CHANGE.md` is
exactly where the heuristic can be wrong.

**Feature PRs are the sweep's scope.** Open, base is trunk, head is an
arbitrary feature/fix/docs branch.

**Stacked PRs** (base is another open PR's head, not trunk) are not in the
merge queue, since their base moves when that PR lands. Gather them anyway and
pass them to the Workflow: they are a hard ordering constraint on the PRs they
sit on top of. Report them as `hold` with the PR they wait for.

Draft PRs are gathered and ordered but never auto-merge; the Workflow's own
eligibility gate excludes them.

## Contributor trust

Whenever the in-scope set has more than one distinct PR author, the sweep
needs a trust policy per non-primary contributor. The primary contributor is
the current git user (`git config user.email`, matched against PR authors via
`gh api user --jq .login`); everyone else needs a recorded level.

The decision is durable, not session-scoped. Unlike the cf merge mode, which
`~/.claude/cf/sessions/<session_id>/merge-mode` deliberately scopes to one
session, a trust call is a standing judgment about a person's work, and
re-asking it every 30 minutes would make the loop mode unusable. It is stored
per repo and per contributor by `scripts/sweep_trust_store.rb`, installed as
`~/.claude/cf/bin/sweep_trust_store.rb`, under
`~/.claude/cf/sweep/<repo_id>/trust.json`, keyed on the same normalized
`repo_id` (`host/path`) `ContributorsTeam` already resolves, so two checkouts
of one repo share one policy.

```
ruby ~/.claude/cf/bin/sweep_trust_store.rb unknown <login>...   # who still needs a call
ruby ~/.claude/cf/bin/sweep_trust_store.rb set <login> <level>  # record one answer
ruby ~/.claude/cf/bin/sweep_trust_store.rb show                 # login => level
```

Ask about exactly the logins `unknown` returns, never about a login already
recorded. Levels, in order:

1. **High trust** (listed first, the recommended default): priority in the
   merge order and the benefit of the doubt in a conflict; normal review.
2. **Standard**: normal review, no priority.
3. **Low trust**: deprioritized in the order, and a stricter bar before it may
   land, a full `cf:code-review` plus a `cf:change` run, not just green CI.
4. **Blocked**: never enters the auto-merge path; held for manual review every
   sweep.

One `AskUserQuestion` call, one question per unknown contributor, header
`Trust`, up to four options each. `AskUserQuestion` takes at most four
questions per call, so with more than four unknown contributors, batch into
consecutive calls of four. Record every answer with `set` immediately, before
running the Workflow, so a run that dies partway still leaves the answers
cached for the next sweep.

To revise a call later: `sweep_trust_store.rb forget <login>` makes that
contributor unknown again and the next sweep re-asks.

Under away mode, skip the question: default every unknown contributor to
Blocked for this run and report the defaults applied. Do NOT call
`sweep_trust_store.rb set` for a guessed answer. The store is durable and
(repo, contributor) scoped, deliberately not session-scoped, and a guess made
because the human was away must not outlive the away session; the next
non-away sweep re-asks that contributor as still unknown.

## Run mode

Orthogonal to trust: trust is "do I believe this person's code", run mode is
"how interactive is this run". Taken from the invocation argument when given,
so an unattended loop never blocks on a question:

- `report` (the default when a bare `/cf:sweep` runs non-interactively):
  analyze and report, merge nothing.
- `land`: report, then drive and merge the eligible queue with one sign-off
  checkpoint before the first merge.
- `auto`: no questions at all after any trust question; drive and merge
  whatever the trust policy and the quality bar allow. This is the loop mode.

With no argument on an interactive run, call `AskUserQuestion` once: header
`Sweep mode`, options **Report only** (first, recommended), **Land with
sign-off**, **Full auto**. This mirrors `cf:drive`'s step-0 sign-off question
and is separate from it: `cf:drive` still runs under its own Full auto when
invoked from here, because a sweep that stopped at two checkpoints per PR
would not be a sweep.

This interactivity check reads the away store: a session with away mode on is
treated as non-interactive, so the question above is skipped and the run
falls back to `report` automatically, the same as any other unattended
invocation. No separate away-mode logic is needed here.

## Loop mode

`/loop 30m /cf:sweep auto` keeps a development trunk current: every tick
re-lists open PRs, reuses the recorded trust policy, re-runs the analysis
against the trunk as it now stands, and lands what is eligible. Each tick is a
full re-analysis, not a resumption; a PR that was `rebase_then_merge` last tick
may be `merge` this tick because its blocker landed. Nothing is cached between
ticks except the trust policy.

When `CHANGE.md` declares a deploy target for trunk (a `change_config` profile
matching the trunk environment), pass its summary into the Workflow so the
infra gates are expressed against the real target, and report the deploy state
of trunk after the last merge of a tick.

## Workflow

0. **(SKILL.md)** Resolve the repo (`git rev-parse --show-toplevel`), the
   protected chain, and trunk, per Scope above. `git fetch origin` so
   behind-trunk counts and trial merges are against the real trunk.
1. **(SKILL.md)** List open PRs:
   `gh pr list --state open --limit 100 --json number,title,url,author,headRefName,baseRefName,headRefOid,isDraft,mergeable,mergeStateStatus,updatedAt`.
   Partition into release PRs (dropped), feature PRs (the sweep set), and
   stacked PRs (constraints only). If the sweep set is empty, report that and
   stop; do not call the Workflow.
2. **(SKILL.md)** Trust, per Contributor trust above: run `unknown`, ask only
   about what it returns, `set` each answer, then `show` for the full map.
   Skip entirely when the set has one distinct author.
3. **(SKILL.md)** Run mode, per Run mode above.
4. **(One `Workflow` call)** Read `reference/workflow.js` and pass its
   contents verbatim as `script`, with
   `args: { repoPath, trunk, protectedBranches, prs, trust, mode, changeConfigSummary }`.
   It gathers each PR's facts in parallel, computes the overlapping file sets
   itself, trial-merges only the pairs that overlap, derives the infra and
   migration gates from the whole set, and synthesizes the trust-weighted
   order. It returns `{ facts, overlapPairs, conflicts, infra, plan, strategy,
   warnings, autoMergeQueue, holds, reportDraft }`. One call for the sweep, not
   one per PR: file overlap, migration ordering, and infra sequencing are only
   answerable with every PR's data at once.
5. **(SKILL.md)** Report, per `reference/summaries.md`'s sweep-summary format.
   Under `report` mode this is the end of the run.
6. **(SKILL.md, `land` mode only)** Landing checkpoint: one summary, at most
   640 characters, one go/no-go for the whole queue. Under `auto`, skip it.
7. **(SKILL.md, `land` and `auto`)** Walk `autoMergeQueue` in order. For each
   PR: post any `warnAuthor` comment first (a warning after the rebase is
   wasted), then invoke `cf:drive` against the PR, instructing it inline to run
   in its own Full auto mode. For a `low` trust PR (`requiresStrictReview`),
   additionally require the `cf:change` comprehensive run to have passed for
   the head SHA before merging, not just CI green. Merge, then re-fetch trunk
   before the next PR: the next PR's mergeability changed the moment this one
   landed. If a merge fails or `cf:drive` cannot reach green, stop the queue,
   report, and leave the rest for the next sweep; do not skip ahead, because
   the order was computed as a sequence.
8. **(SKILL.md)** After the last merge, report what landed, what is left, and
   any gate (a `terraform apply`, a breaking migration) still waiting on a
   human.

## Merge mode and the change gate

The sweep never bypasses either gate the toolkit already enforces.

The session's active cf merge mode governs step 7 exactly as it governs
`cf:drive`'s push. Under **Local only**, steps 0-6 still run in full and the
report is the deliverable; step 7 does not run. **Merge ready** analyzes,
drives, and pushes, but stops short of merging: the report becomes a merge
order for the maintainer to execute. Only **Admin bypass** and **Yolo** reach
an actual `gh pr merge`, and a sweep asked to land under Merge ready says so
plainly rather than merging anyway.

When trunk is itself a protected branch (`protected_branches: [main]` is the
common case), every merge in step 7 is additionally gated by
`change_merge_guard.rb`, which requires a passing comprehensive `cf:change`
run recorded for the PR's head SHA. That is why step 7 runs `cf:drive` per PR
rather than merging directly: `cf:drive`'s own `cf:change` lane produces that
record. A sweep never sets `CF_ALLOW_UNGATED_MERGE` and never invokes
`change_override.rb`; an ungated merge is a human's call, made from a human's
terminal.

This skill never runs `terraform plan` or `terraform apply`, and never runs a
migration. It names the step, orders the PRs around it, and holds the PRs that
depend on it until a human reports it done.

## Failure modes

- No `CHANGE.md`, or no `change_policy`: fall back to the default branch plus
  the conventional environment-name heuristic in Scope. Say which rule was
  applied in the report; do not present the heuristic's scope as authoritative.
- Empty sweep set (no open feature PRs): report and stop at step 1. Under loop
  mode this is the normal steady state and should be one line, not a report.
- One author only: no trust question fires at all, and the order is decided on
  dependency, conflict, and risk alone.
- An author recorded as `blocked`: their PRs are always gathered and always
  ordered, so the report stays honest about what is open, but they never enter
  `autoMergeQueue` and the report says why.
- `gh` not authenticated or rate-limited: stop before the Workflow call and
  report it. A partial PR list would silently produce a wrong order, which is
  worse than no order.
- A trial merge in the Conflict phase cannot run (a shallow clone, a missing
  head ref): that pair is reported as conflicting until checked by hand. Fail
  closed; an unverified clean merge is not a clean merge.
- A PR's fact gathering returns nothing: it stays in the report, is never
  auto-merge eligible, and is flagged for a human.
- The `Workflow` call errors or returns no result: say so and stop. Do not
  hand-assemble an order from the raw PR list; the order is the deliverable and
  a guessed one is worse than none.
- A merge in step 7 fails: stop the queue at that PR, per step 7. The remaining
  PRs are re-analyzed from scratch on the next sweep, which is exactly what
  loop mode does 30 minutes later.
