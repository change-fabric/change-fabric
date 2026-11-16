---
name: cf:sweep
group: workflow
description: Sweeps a repo's open feature pull requests and plans how to land them as a group. It covers merge order, trial-merged conflict mitigations, terraform and migration sequencing, and a per-contributor trust policy persisted across runs. Runs unattended by default, landing only what the trust policy and the merge mode allow; report and land modes and --signoff make it more conservative, and it suits /loop for keeping a development environment current.
---

# CF Sweep

Analyze every open feature pull request in the current repo as one set, then
land them in an order that holds up.

Trigger: `/cf:sweep [report|land|auto] [--signoff]`, or stack mode:
`/cf:sweep stack <plan_dir | #a #b ...>`, `/cf:sweep stack resume`,
`/cf:sweep stack status`.

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
- `reference/stack.md`: the stack mode loop in full. Read before any
  `/cf:sweep stack` invocation.

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

Whenever the in-scope set has any PR author other than the primary
contributor, the sweep needs a trust policy per non-primary contributor, even
when that author is the only one in the set. The primary contributor is
the current git user (`git config user.email`, matched against PR authors via
`gh api user --jq .login`); everyone else needs a recorded level. When either
lookup fails (no `git config user.email`, or `gh api user` errors), there is
no primary contributor to exempt: every in-scope author is treated as
non-primary and needs a recorded level before auto mode runs.

The decision is durable, not session-scoped. Unlike the cf merge mode, which
the shared CF session state deliberately scopes to one
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
"how interactive is this run". Taken from the invocation argument when given:

- `report`: analyze and report, merge nothing. Do not ask whether to start:
  under Merge ready, go straight on to `/cf:drive quick` for the head of line
  in `autoMergeQueue` and hand off its URL, then take the next one as each
  merges, one PR at a time (see One PR at a time below). An empty queue ends
  the run at the report.
- `land`: report, then drive and merge the eligible queue with one sign-off
  checkpoint before the first merge.
- `auto` (the default): no questions at all after any trust question; drive
  and merge whatever the trust policy and the quality bar allow. This is the
  loop mode.

`auto` is the default whenever no mode word is given, interactive or not, away
or not. Merge mode still gates every merge: under Merge ready, step 7 drives
the head PR, hands off its URL, arms `stack_watch.rb`, and on merge rebases
and readies the next (see Merge mode and the change gate below).

`--signoff` with no mode word calls `AskUserQuestion` once: header `Sweep
mode`, options **Report only** (first, recommended), **Land with sign-off**,
**Full auto**. A mode word always wins over `--signoff`. A literal `full auto`
maps to `auto`, with a one-line note that it is already the default. Under
away mode `--signoff` is ignored and the run reports that it assumed `auto`.
`cf:drive` still runs straight through when invoked from here, because a sweep
that stopped at two checkpoints per PR would not be a sweep.

## Loop mode

`/loop 30m /cf:sweep auto` keeps a development trunk current: every tick
re-lists open PRs, reuses the recorded trust policy, re-runs the analysis
against the trunk as it now stands, and lands what is eligible. A tick that
finds an unfinished `sweep-*` record for the repo (or any other ACTIVE claim)
resumes that queue, or stops naming the holder, and never starts a second
queue. The recorded queue wins until it finishes, even if the order would now
differ (a new PR opened, a hold cleared): new PRs wait for the next queue.
Only once no queue is open is a tick a full re-analysis; a PR that was
`rebase_then_merge` last time may be `merge` now because its blocker landed.
Nothing is cached between ticks except the trust policy and the open queue.

When `CHANGE.md` declares a deploy target for trunk (a `change_config` profile
matching the trunk environment), pass its summary into the Workflow so the
infra gates are expressed against the real target, and report the deploy state
of trunk after the last merge of a tick.

## One PR at a time

Every sweep mode (report, land, auto, stack, and a loop tick) works on one PR
at a time. The head of line is the first PR in `autoMergeQueue` (or the stack
order) that has not merged. Only the head is rebased, pushed to, driven,
cf:change-gated, handed off, or merged [SW-7]. Every other queued PR is
"queued, untouched" until it becomes head. Never run cf:change on a PR that is
not head of line. At most one write agent per repo; read-only fan-out
(gathering facts, overlap checks, trial merges) stays parallel.

Change Fabric prefers rebase over merge and a linear history, regardless of
the repo's branch protection settings: the chef's choice, not a probe of what
the repo happens to require. Why serial: each merge puts every other open PR
BEHIND, and the rebase that follows changes its head SHA, which throws away
its CI run and its SHA-keyed cf:change gate record. Work done in parallel on
the rest of the queue is wasted.

The rule is enforced, not only written. Every mode records its queue with
`stack_store.rb init` (non-stack slug `sweep-<first>-<last>`, the first and
last PR numbers of `autoMergeQueue`, source `sweep`), and `set-pr` refuses
`preparing` or `handed_off` on any PR that is not the head.

### Controls

- Queue order: `scripts/stack_store.rb` enforces head-only transitions. It
  does not check gh and does not decide the merge method.
- One active queue per repo: the ACTIVE claim, below.
- One executor per queue: the LEASE, below.
- Merge confirmation: the sweep always confirms a merge with
  `gh pr view <n> --json state,mergedAt` before `advance`. This check lives
  here in the skill, not in the store.
- Merge method: squash or rebase only, below.

### Active-queue claim

`~/.claude/cf/stack/<repo_dir>/ACTIVE` names the one queue that owns the repo,
in every mode including stack and loop. `stack_store.rb claim <slug>` creates
it (or resumes, `{"claim":"resumed"}`, when it already names this slug); a
claim held by another slug exits non-zero with `{"error":"held","holder":...}`.
`init` refuses without the claim. `release <slug>` removes it only for its own
slug; `clear` also releases. A run that gets `held` stops and reports the
holder slug with its `/cf:sweep stack resume` or `stack_store.rb clear <slug>`
command. It never starts a second queue.

### Executor lease

`LEASE` says which run is executing the queue; it is exclusive even for the
same slug. Acquire, heartbeat, takeover, atomic publish, and `release --stale`
are in `reference/stack.md`, Executor lease.

### Command sequence

`S=~/.claude/cf/bin/stack_store.rb`. Base slug `sweep-<first>-<last>` (stack
mode keeps its own slug).

1. `ruby $S resolve <base>`: ACTIVE wins whatever its suffix; otherwise the
   highest unfinished `<base>` or `<base>-<N>` resumes; otherwise `new` at the
   first free suffix. Any unfinished `sweep-*` queue resumes even when its
   endpoints have shifted as PRs merged. A finished record is archived, never
   revived, so a new queue over the same PRs is `<base>-2`, then `-3`. A held
   claim stops here.
2. `ruby $S claim <slug> --source sweep`, then `ruby $S lease <slug>
   --session <id>` before anything writes the record; a `leased` reply
   stops the run here.
3. New: `ruby $S init <slug> --repo o/r --source sweep --mode <merge mode>
   --pr N:URL:HEAD:SHA ...` for each queued PR in order. `init` refuses an
   existing record, finished or not, so a late duplicate can never reset a
   live queue. Resume: the resume table below.
4. Per head PR: `ruby $S set-pr <slug> <n> state=preparing`, rebase onto
   origin/<trunk> and `/cf:drive quick` nested under cf:sweep, then hand off or
   merge by merge mode, then `gh pr view <n> --json state,mergedAt` must say
   MERGED and the linear-history check must pass, then `ruby $S advance <slug>
   --expect <n>`. Only then is the next PR touched.
5. After the last PR: `ruby $S release <slug>` and `ruby $S unlease <slug>
   --session <id>`.

### Resume table

Always run `gh pr view <n> --json state,mergedAt,headRefOid` on the head
first; gh is the truth, the store is intent.

| Store state of head | gh says | Action |
|---|---|---|
| any | MERGED | run the parent-count check first (Linear-history checks); linear: `advance <slug> --expect <n>`; merge commit: stay or go `paused` with `merge-commit` and escalate, never advance |
| any | CLOSED unmerged | escalate, `pause <slug> closed` |
| pending | OPEN | start step 4 |
| preparing | OPEN | re-run drive from the rebase (idempotent) |
| handed_off | OPEN, head is `old_head_sha` | never re-drive; re-arm the watcher (Handoff boundary) |
| handed_off | OPEN, head moved | a push landed while nobody watched: `set-pr <slug> <n> state=preparing` and prepare again |
| paused | OPEN | unattended tick: report the reason and stop. Explicit resume by the user after the cause is cleared: `set-pr <slug> <n> state=preparing` and prepare again |
| escalated | OPEN | report the recorded reason; do not continue |

### Handoff boundary

The order is fixed: (a) `set-pr <slug> <n> state=handed_off
old_head_sha=<sha>`, (b) post the PR's absolute URL, (c) arm `stack_watch.rb
--pr <n> --repo o/r --expect-sha <sha> --baseline-sha <sha> --lease <slug>
--session <id>` in the background; it heartbeats the lease every poll, so a
long wait never lets it expire. Resume never
re-drives a handed_off head; it re-posts nothing and only re-arms the watcher.
The handoff message says "squash or rebase only, no merge commit".

Watcher exit 0: confirm via gh, run the parent-count check, then `advance
<slug> --expect <n>`. Exit 4 (foreign push), 5, or 6: `set-pr <slug> <n>
state=preparing` and prepare the same head again. Exit 3, 7, or 2: `pause
<slug> <reason>` (or escalate) and report. No non-zero exit ever moves to the
next PR; the full table is in `reference/stack.md`.

### Merge method

Squash (the repo rule) or rebase only, never a merge commit. Admin bypass:
`gh pr merge <n> --squash --admin`. Yolo: rebase and `git push origin
HEAD:<trunk>`. If the repo allows neither squash nor rebase, escalate; never fall
back to a merge commit.

### Linear-history checks

- Preflight, once per run: `gh api repos/{o}/{r} --jq '.allow_merge_commit'`;
  if true, warn once in the summary that the repo allows merge commits but CF
  does not.
- After gh confirms a merge, before `advance`: `git fetch origin <trunk>`, take
  the oid from `gh pr view <n> --json mergeCommit`, and run `git rev-list
  --parents -n 1 <oid>`. More than one parent means a merge commit landed:
  `pause <slug> merge-commit` and escalate (`StackStore.merge_commit?` is the
  same check in Ruby).

## Workflow

0. **(SKILL.md)** Identify the repo (`git rev-parse --show-toplevel`), the
   protected chain, and trunk, per Scope above. `git fetch origin` so
   behind-trunk counts and trial-merge checks are against the real trunk
   [SW-3].
1. **(SKILL.md)** [SW-6] List open PRs: `gh pr list --state open --limit 101
   --json number,title,url,author,headRefName,baseRefName,headRefOid,isDraft,mergeable,mergeStateStatus,updatedAt`,
   one above the 100-PR cap this sweep plans against (`--limit` is a hard
   ceiling on what `gh pr list` returns, default 30), so a full page is
   detectable instead of looking identical to a complete list.
   101 results back means the repo has more open PRs than fit in one page and
   the set in hand is truncated; a truncated set can only ever yield a wrong
   landing order, since the Workflow would be sequencing against PRs it never
   saw. Drop mode to `report` regardless of the requested mode, say the cap
   was hit and by how many (count open PRs with `gh pr list --state open
   --limit 9999 --json number --jq length`, since without a high `--limit`
   it stops at 30; do not re-run the fields query a second time),
   and hold every PR gathered rather than computing any order from the
   partial set [SW-6]. Fewer than 101 results is the complete list; proceed
   as normal. Partition into release PRs (dropped), feature PRs (the sweep
   set), and stacked PRs (constraints only). If the sweep set is empty,
   report that and stop; do not call the Workflow.
2. **(SKILL.md)** [SW-1] Trust, per Contributor trust above: run `unknown`, ask only
   about what it returns, `set` each answer, then `show` for the full map.
   Skip only when every in-scope author is the primary contributor; a sole
   external author still gets a recorded level before auto mode runs.
3. **(SKILL.md)** Run mode, per Run mode above.
4. **(One `Workflow` call)** [SW-1][SW-3] Read `reference/workflow.js` and pass its
   contents verbatim as `script`, with
   `args: { repoPath, trunk, protectedBranches, prs, trust, mode, changeConfigSummary }`.
   It gathers each PR's facts in parallel, computes the overlapping file sets
   itself, trial-merges only the pairs that overlap, derives the infra and
   migration gates from the whole set, and synthesizes the trust-weighted
   order. It returns `{ facts, overlapPairs, conflicts, infra, plan, strategy,
   warnings, autoMergeQueue, holds, reportDraft }`. One call for the sweep, not
   one per PR: file overlap, migration ordering, and infra sequencing are only
   answerable with every PR's data at once.
5. **(SKILL.md)** [SW-3] Report, per `reference/summaries.md`'s sweep-summary format.
   Under `report` mode the run ends here, except under Merge ready, where it
   continues at once (no go/no-go question) into step 7's head-of-line loop
   (never a held PR). An empty queue ends the run here.
6. **(SKILL.md, `land` mode only)** Landing checkpoint: one summary, at most
   640 characters, one go/no-go for the whole queue. Under `auto`, skip it.
7. **(SKILL.md, `land` and `auto`, and `report` under Merge ready)**
   [SW-2][SW-4][SW-5][SW-7] The head-of-line loop. Init or resume the store
   per the Command sequence above, then for the head PR only: post any
   `warnAuthor` comment first (a warning after the rebase is wasted),
   `set-pr <slug> <n> state=preparing`, then invoke `/cf:drive quick` against
   the PR (the bare form is
   thorough, which plans instead of landing), with the inline instruction
   `nested under cf:sweep` (cf:drive runs straight through by default; the
   instruction makes a recurrence stop record a pointer instead of starting
   cf:plan). That instruction also tells drive to rebase the branch onto
   origin/<trunk> (trunk per Scope) before driving it (a BEHIND or `rebase_then_merge` PR reaches
   the head only after every PR ahead of it merged, so the rebase is onto
   trunk, never onto an unmerged PR), and drive pushes the rebase to the
   contributor's own branch; sweep never rebases or pushes by itself. Under
   Merge ready, hand off per the Handoff boundary above: record handed_off,
   post the URL, arm `stack_watch.rb`, and wait; watcher exit codes are in
   `reference/stack.md`. Under Admin bypass and Yolo, merge per SW-2 and
   SW-4 below. Either way, gh must confirm the merge before `stack_store.rb
   advance <slug> --expect <n>`, and no next PR is driven before that
   confirmation. Read
   drive's emitted `drive-result` block (`ciGreen`, `headSha`, `stoppedReason`)
   rather than inferring state from its prose; merge only when `ciGreen` is
   true, `headSha` matches the PR's current head, and `stoppedReason` is
   absent, regardless of whether drive approved (drive may skip approval on
   its own PR, which is not a reason to withhold the merge). For a `low`
   trust PR (`requiresStrictReview`), the nested instruction forces drive's
   `cf:change` lane on regardless of drive's own relevance call, and merging
   additionally requires a passing comprehensive `cf:change` run recorded for
   the head SHA; a missing record holds the PR rather than merging on CI
   green alone. After the merge, re-fetch trunk, `advance`, and re-read the
   new head from gh: its mergeability changed the moment this one landed. If
   a merge fails, `cf:drive`'s `drive-result` reports `stoppedReason`, or it
   stops on recurrence, stop the queue, report, and leave the rest for the next
   sweep; do not skip
   ahead, because the order was computed as a sequence.
8. **(SKILL.md)** [SW-2] After the last merge, report what landed, what is left, and
   any gate (a `terraform apply`, a breaking migration) still waiting on a
   human. Name any pending root-cause plan (its ctx pointer and `/cf:plan`
   command) first in the report.

## Merge mode and the change gate

The sweep never bypasses either gate the toolkit already enforces.

The session's active cf merge mode governs step 7 exactly as it governs
`cf:drive`'s push. Under **Local only**, steps 0-6 still run in full and the
report is the deliverable; step 7 does not run. **Merge ready** analyzes,
drives the head PR, hands it off, and waits for the maintainer's merge before
touching the next. Only **Admin bypass** and **Yolo** reach an actual merge,
and a sweep asked to land under Merge ready says so plainly rather than
merging anyway.

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

## Stack mode

Stack mode lands a batch or stack of PRs strictly one at a time, in a fixed
order, instead of computing an order for every open PR. cf:plan hands off to
it by default for any plan with more than one PR phase.

- `/cf:sweep stack <plan_dir | #a #b ...>` starts a stack from a plan
  directory (one PR per phase) or an explicit PR list (slug
  `prs-<first>-<last>`), recorded with `stack_store.rb claim` then
  `stack_store.rb init`, and released with `stack_store.rb release` after
  the last PR merges. A stack from a plan records each PR's phase as `stack_store.rb set-pr <slug> <n>
  'phase=<area>/<slug>#Phase N'`, taken from the plan's `### Phase N`
  heading the PR lands; that field is the recorded link. Position in the
  stack stays the fallback only for old records with no `phase`.
- `/cf:sweep stack resume` re-derives state from gh and continues at the
  current PR, the first one not merged.
- `/cf:sweep stack status` prints the store merged with live gh state, plus
  the count of judged decisions and the plan.md path.

Per PR: re-derive state from gh, rebase onto origin/<trunk> (`git rebase --onto
origin/<trunk> <parent-old-head> <head>` once the parent squash merged, then
`gh pr edit <n> --base <trunk>`), prepare with cf:drive quick nested under
cf:sweep stack (CI green, cf:resolve-threads run, no approval review), handle
recurrence, hand off, advance the store.

| Merge mode | Hand-off |
|---|---|
| merge ready | Post the PR's absolute URL; arm `stack_watch.rb` in the background; advance on merge or a "merged #N" message. |
| admin bypass | Escalate if CHANGE.md forbids admin bypass; pass the cf:change gate when `ChangeGateCheck.required?` says so; `gh pr merge <n> --squash --admin`. |
| yolo | No PRs. Rebase, test, `git push origin HEAD:<trunk>`, next branch. |
| local only | Stack mode does not run; say so. |

Gates: a resolve-threads recurrence plan pauses the stack under merge ready
for a human `/cf:plan` interview and runs `/cf:plan --judge` under admin
bypass. A closed PR, cf:change exit 2, a CHANGE.md block, or a rejected yolo
push escalates. `change_policy.gate.require_on` is available from spec
0.14.0; absent, the gate applies to every merge. The watcher exit codes
(0 merged, 3 closed, 4 foreign push, 5 new thread, 6 red check, 7 timeout,
2 setup error) and the full loop are in `reference/stack.md`.

## Unattended gates

| ID | Action | Requires | When unmet |
|---|---|---|---|
| SW-1 | Ask, or silently apply, a trust level | Author known by gh login; one primary-contributor-only set skips the question | Unknown author is blocked, never standard |
| SW-2 | Merge a queued PR | Drive's `drive-result` block: `ciGreen && headSha` matches the PR's current head `&& !stoppedReason` | Hold; never merge on approval or prose alone |
| SW-3 | Add a PR to `autoMergeQueue` | No conflict, `mergeable: MERGEABLE`, `mergeStateStatus` present and one of CLEAN/HAS_HOOKS/UNSTABLE/BEHIND (missing fails closed; BEHIND is rebased at head of line), base is trunk per gh (not the agent), not stacked, infra/migration gated, present in the computed order | Hold |
| SW-4 | Merge a `low` trust PR | A passing comprehensive `cf:change` run recorded for the head SHA | Hold even with green CI; a missing record never substitutes |
| SW-5 | Push a fix or rebase commit to another contributor's branch | Allowed unattended (drive performs the push, never sweep itself) | N/A |
| SW-6 | Run `auto` or `land` mode, or compute any landing order at all | `gh pr list --limit 101` returns fewer than 101 PRs (the full open set fit in one page) | Force `report` mode, hold every gathered PR, and say the cap was hit and by how many |
| SW-7 | Rebase, push to, drive, cf:change-gate, hand off, or merge a PR | It is head of line (first unmerged in the recorded queue) and `stack_store.rb set-pr` accepted the transition | Leave it queued, untouched |

## Failure modes

- No `CHANGE.md`, or no `change_policy`: fall back to the default branch plus
  the conventional environment-name heuristic in Scope. Say which rule was
  applied in the report; do not present the heuristic's scope as authoritative.
- Empty sweep set (no open feature PRs): report and stop at step 1. Under loop
  mode this is the normal steady state and should be one line, not a report.
- More open PRs than the 101-PR page fetched in step 1: fail closed [SW-6].
  A bare sweep (the default `auto`) never silently computes a landing order
  from a truncated set; it drops to `report` and holds every PR it gathered
  rather than guessing an order that is missing PRs it never saw.
- One author only, and that author is the primary contributor: no trust
  question fires [SW-1], and the order is decided on dependency, conflict,
  and risk alone. A sole author who is not the primary contributor still
  gets a recorded level first, per step 2; this is not a contradiction of
  the single-author case above, only a restriction of it.
- An author recorded as `blocked`: their PRs are always gathered and always
  ordered, so the report stays honest about what is open, but they never enter
  `autoMergeQueue` and the report says why [SW-1].
- `gh` not authenticated or rate-limited: stop before the Workflow call and
  report it. A partial PR list would silently produce a wrong order, which is
  worse than no order.
- A trial merge in the Conflict phase cannot run (a shallow clone, a missing
  head ref): that pair is reported as conflicting until checked by hand [SW-3].
  Fail closed; an unverified clean merge is not a clean merge.
- A PR's fact gathering returns nothing: it stays in the report, is never
  auto-merge eligible [SW-3], and is flagged for a human.
- The `Workflow` call errors or returns no result: say so and stop. Do not
  hand-assemble an order from the raw PR list; the order is the deliverable and
  a guessed one is worse than none.
- A merge in step 7 fails: stop the queue at that PR, per step 7 [SW-2]. The
  next sweep resumes the recorded queue at that PR (the resume table), which
  is exactly what loop mode does 30 minutes later.
- Store refuses a transition: a second PR was about to be driven; stop and
  report [SW-7]. Never work around the guard by editing the record.
- An unfinished `sweep-*` record from an aborted run blocks a new queue:
  resume it. `stack_store.rb clear <slug>` is the documented manual reset.
- `claim` or `lease` returns held or leased: another queue or run owns the
  repo; stop and name the holder. `release <slug> --stale` recovers a claim
  left by a run that died before `init`.
