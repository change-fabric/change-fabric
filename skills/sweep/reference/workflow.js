// cf:sweep Workflow script. Pass this file's contents verbatim as Workflow's
// `script` argument; do not paraphrase, summarize, or edit it in transit. It
// owns the cross-PR analysis: per-PR fact gathering, real trial-merge conflict
// checks on the pairs that actually overlap, infrastructure and migration
// sequencing, and the trust-weighted merge order. Scope resolution, the trust
// question, the sign-off checkpoint, and the actual merges stay outside it
// (SKILL.md's steps 0-3 and 6-8), since those need a gh call, a human ask, or a
// write action this script has no tool to make.
//
// This is one Workflow call for the whole sweep, not one per PR. A per-PR call
// could not see file overlap between two PRs, could not order a shared
// terraform module ahead of the app changes that consume it, and could not
// decide which of two migrations lands first. Those answers only exist with
// every in-scope PR's data in hand, which is why the parallel Gather phase ends
// in a barrier.
//
// For maintainers: this script's own logic is documented inline below. For the
// Workflow tool's general API (agent/pipeline/parallel/phase/schema semantics),
// see https://code.claude.com/docs/en/workflows.md and the full signature
// reference at https://code.claude.com/docs/en/agent-sdk/typescript. This script
// runs in a sandboxed context with no tool access, so nothing here can fetch
// those docs at runtime, and none of the git/gh work below happens in this
// script either; every `agent()` call is a real sub-agent with tool access.
//
// Model tiers:
//   Gather    inherit  Runs real gh/git commands per PR and classifies the
//                      changed paths; mechanical but tool-driven.
//   Conflict  inherit  Must perform an actual trial merge, not predict one.
//   Infra     opus     One call, whole-repo blast radius: gets terraform and
//                      migration ordering wrong and a deploy breaks.
//   Order     opus     The barrier synthesis every later merge follows.

export const meta = {
  name: "cf-sweep-plan",
  description: "Gather every in-scope feature PR, trial-merge the overlapping pairs, then plan a trust-weighted landing order",
  phases: [
    { title: "Gather" },
    { title: "Conflict" },
    { title: "Infra", model: "opus" },
    { title: "Order", model: "opus" }
  ]
}

const FACTS_SCHEMA = {
  type: "object",
  properties: {
    number: { type: "number" },
    author: { type: "string" },
    changedFiles: { type: "array", items: { type: "string" } },
    additions: { type: "number" },
    deletions: { type: "number" },
    ciState: { type: "string", enum: [ "green", "red", "pending", "none" ] },
    failingChecks: { type: "array", items: { type: "string" } },
    behindTrunk: { type: "number" },
    stackedOn: { type: "number" },
    touchesInfra: { type: "boolean" },
    infraPaths: { type: "array", items: { type: "string" } },
    infraShared: { type: "boolean" },
    touchesMigrations: { type: "boolean" },
    migrationPaths: { type: "array", items: { type: "string" } },
    migrationCompatibility: { type: "string", enum: [ "additive", "breaking", "unknown", "none" ] },
    risk: { type: "string", enum: [ "low", "medium", "high" ] },
    summary: { type: "string" }
  },
  required: [
    "number", "author", "changedFiles", "ciState", "behindTrunk",
    "touchesInfra", "touchesMigrations", "migrationCompatibility", "risk", "summary"
  ]
}

const CONFLICT_SCHEMA = {
  type: "object",
  properties: {
    conflicts: { type: "boolean" },
    conflictedFiles: { type: "array", items: { type: "string" } },
    recommendedFirst: { type: "number" },
    mitigation: { type: "string" }
  },
  required: [ "conflicts", "mitigation" ]
}

const INFRA_SCHEMA = {
  type: "object",
  properties: {
    gates: {
      type: "array",
      items: {
        type: "object",
        properties: {
          kind: { type: "string", enum: [ "terraform", "migration", "other" ] },
          description: { type: "string" },
          appliesTo: { type: "array", items: { type: "number" } },
          mustLandBefore: { type: "array", items: { type: "number" } },
          manualStep: { type: "string" },
          severity: { type: "string", enum: [ "blocking", "advisory" ] }
        },
        required: [ "kind", "description", "appliesTo", "severity" ]
      }
    },
    notes: { type: "string" }
  },
  required: [ "gates", "notes" ]
}

const ORDER_SCHEMA = {
  type: "object",
  properties: {
    order: {
      type: "array",
      items: {
        type: "object",
        properties: {
          number: { type: "number" },
          action: { type: "string", enum: [ "merge", "rebase_then_merge", "hold", "needs_human" ] },
          rationale: { type: "string" },
          blockedBy: { type: "array", items: { type: "number" } },
          warnAuthor: { type: "string" }
        },
        required: [ "number", "action", "rationale" ]
      }
    },
    strategy: { type: "string" },
    warnings: { type: "array", items: { type: "string" } }
  },
  required: [ "order", "strategy" ]
}

// Some hosts hand this script a JSON-encoded string instead of the parsed
// object the Workflow contract promises; tolerate both.
const scope = typeof args === "string" ? JSON.parse(args) : args

const repoPath = scope.repoPath
const trunk = scope.trunk
const protectedBranches = scope.protectedBranches ?? [ trunk ]
const prs = scope.prs ?? []
const trust = scope.trust ?? {}
const mode = scope.mode ?? "report"
const changeConfigSummary = scope.changeConfigSummary ?? null

// Trust is ordinal and drives two separate things: where a PR sorts in the
// order, and whether it may enter the auto-merge path at all. Kept here rather
// than left to the Order agent's prose reading of the levels so both uses read
// the same scale.
const TRUST_RANK = { high: 0, standard: 1, low: 2, blocked: 3 }
const DEFAULT_TRUST = "standard"

function trustOf(author) {
  return trust[author] ?? DEFAULT_TRUST
}

const INFRA_CONVENTIONS =
  "Infrastructure-as-code paths follow cf:terraform's and cf:aws's own detection conventions: " +
  "*.tf, *.tfvars, .terraform.lock.hcl, and for AWS, cdk.json, serverless.yml/yaml, samconfig.toml, " +
  "template.yml/yaml. Treat a change under a shared module directory (modules/, or any path more than " +
  "one root module depends on) as shared infra, not app-local infra."

const MIGRATION_CONVENTIONS =
  "Migration paths follow what cf:prisma, cf:drizzle, and cf:postgres-sql already key on: " +
  "prisma/migrations/**, drizzle/** plus drizzle.config.*, db/migrate/**, migrations/**/*.sql, and " +
  "any *.sql under a directory whose name is migrations. Classify compatibility as additive (new " +
  "nullable column, new table, new index), breaking (drop, rename, narrowing type change, NOT NULL " +
  "without a default, or anything the currently deployed app version cannot run against), or unknown."

phase("Gather")
// Independent per PR: each one reads only its own diff and checks, so this
// fans out. The cross-PR work all happens after this barrier.
const gathered = await parallel(prs.map((pr) => () =>
  agent(
    "Gather the landing facts for pull request #" + pr.number + " (" + pr.title + ") in the " +
    "repository at " + repoPath + ", head branch " + pr.headRef + ", base " + pr.baseRef + ", " +
    "author " + pr.author + ".\n\n" +
    "Run the real commands, do not infer: `gh pr view " + pr.number + " --json files,additions," +
    "deletions,author,isDraft,mergeable,mergeStateStatus`, `gh pr checks " + pr.number + "` for the " +
    "check state and the names of any failing check, and `git -C " + repoPath + " rev-list --count " +
    pr.headRef + "..origin/" + trunk + "` for how far behind trunk the head is (fetch first). " +
    "Set stackedOn to the number of another open PR in this set whose head branch this branch is " +
    "built on (its merge-base with that head is ahead of trunk), or omit it when the branch comes " +
    "straight off " + trunk + ".\n\n" + INFRA_CONVENTIONS + "\n\n" + MIGRATION_CONVENTIONS + "\n\n" +
    "Rate risk from the size of the diff, the blast radius of what it touches (shared module, " +
    "migration, auth, CI config, lockfile) and its CI state. summary is one line a maintainer can " +
    "read in a merge queue, not a restatement of the title.\n\n" +
    "Open PRs in this sweep: " + prs.map((p) => "#" + p.number + " " + p.headRef).join(", "),
    { phase: "Gather", label: "#" + pr.number, schema: FACTS_SCHEMA }
  ).then((f) => (f ? { ...pr, ...f } : { ...pr, gatherFailed: true, changedFiles: [], ciState: "none", risk: "high", summary: "gather agent returned no result" }))
))

const facts = gathered.filter(Boolean)
log("Gathered " + facts.length + " of " + prs.length + " in-scope PR(s)")

// Candidate conflict pairs are computed here rather than by an agent: set
// intersection is exact, and spending an agent call on every pair, including
// the disjoint majority, would scale quadratically for no added information.
// The agent's job is the part JS cannot do, deciding whether a shared file is
// an actual textual conflict, and it only runs on pairs that share a file.
function overlapOf(a, b) {
  const other = new Set(b.changedFiles || [])
  return (a.changedFiles || []).filter((f) => other.has(f))
}

const overlapPairs = []
for (let i = 0; i < facts.length; i++) {
  for (let j = i + 1; j < facts.length; j++) {
    const shared = overlapOf(facts[i], facts[j])
    if (shared.length > 0) overlapPairs.push({ a: facts[i], b: facts[j], shared })
  }
}
log(overlapPairs.length + " overlapping pair(s) of " + (facts.length * (facts.length - 1)) / 2)

phase("Conflict")
const conflicts = await parallel(overlapPairs.map((pair) => () =>
  agent(
    "Two open pull requests change the same files. Find out whether they actually conflict, by " +
    "merging them for real in a throwaway checkout, never in " + repoPath + " itself: run " +
    "`d=$(mktemp -d) && git -C " + repoPath + " worktree add \"$d\" origin/" + trunk + "`, then " +
    "inside that path merge " + pair.a.headRef + " and then " + pair.b.headRef + ". Remove the " +
    "worktree with `git -C " + repoPath + " worktree remove \"<path>\" --force` when done.\n\n" +
    "PR #" + pair.a.number + " (" + pair.a.author + ", trust " + trustOf(pair.a.author) + "): " +
    pair.a.summary + "\nPR #" + pair.b.number + " (" + pair.b.author + ", trust " +
    trustOf(pair.b.author) + "): " + pair.b.summary + "\n\nShared files:\n" + pair.shared.join("\n") +
    "\n\nIf they conflict, name the conflicted files and give a concrete mitigation: which one should " +
    "land first, who rebases on whom afterwards, and whether the second author should be warned " +
    "before spending time on a merge that is already doomed. Prefer landing the smaller or " +
    "lower-risk change first unless a real dependency says otherwise; where the two are otherwise " +
    "equivalent, the higher-trust author's PR goes first. Set recommendedFirst to that PR's number. " +
    "If the merge is clean, say so plainly and set conflicts false.",
    { phase: "Conflict", label: "#" + pair.a.number + "+#" + pair.b.number, schema: CONFLICT_SCHEMA }
  ).then((c) => ({
    a: pair.a.number,
    b: pair.b.number,
    shared: pair.shared,
    ...(c || { conflicts: true, mitigation: "conflict agent returned no result; treat as conflicting until checked by hand" })
  }))
))

phase("Infra")
// The first genuine barrier: sequencing infrastructure and schema changes is
// only answerable with every PR's classification in hand. A shared terraform
// module that three PRs consume has to be applied before them, and that is not
// visible from any one PR.
const infraCandidates = facts.filter((f) => f.touchesInfra || f.touchesMigrations)
const infra = infraCandidates.length === 0
  ? { gates: [], notes: "No PR in this sweep touches infrastructure-as-code or a migration." }
  : await agent(
      "Decide the infrastructure and schema sequencing constraints across this whole set of open " +
      "pull requests against " + repoPath + ". You have every PR's classification; use the set, not " +
      "one PR at a time.\n\n" +
      "Terraform and other IaC: when a PR changes shared or core infrastructure that another PR's " +
      "application code depends on, that infra change must land AND be planned/applied before the " +
      "dependent PRs merge, never after. Say which PR carries the infra change, which PRs depend on " +
      "it, and what the manual step is (`terraform plan` reviewed, then `terraform apply` against " +
      "which workspace), as manualStep. This sweep never runs plan or apply itself; it names the " +
      "step and gates the order on it.\n\n" +
      "Migrations: two PRs both adding migrations need a deterministic order, or their generated " +
      "timestamps and any checksum-based migration table will fight. Additive migrations land " +
      "first and can ship ahead of the code that uses them; a backward-incompatible migration lands " +
      "last, after every deployed reader is off the old shape, and gets its own gate. Flag any pair " +
      "whose migrations touch the same table.\n\n" +
      (changeConfigSummary ? "The repo's CHANGE.md declares this deploy target for trunk:\n" + changeConfigSummary + "\n\n" : "") +
      "PR classifications:\n" + JSON.stringify(facts.map((f) => ({
        number: f.number,
        author: f.author,
        infraPaths: f.infraPaths,
        infraShared: f.infraShared,
        migrationPaths: f.migrationPaths,
        migrationCompatibility: f.migrationCompatibility,
        summary: f.summary
      })), null, 2),
      { model: "opus", phase: "Infra", schema: INFRA_SCHEMA }
    )

phase("Order")
// The second barrier and the point of the whole sweep: one order for the set,
// weighing conflicts, infra gates, CI state, staleness, size, and trust
// together. No per-PR call can produce this.
const plan = await agent(
  "Produce the landing order for this set of open feature pull requests targeting " + trunk +
  " in " + repoPath + ". Order the whole set; do not evaluate them one at a time.\n\n" +
  "Weigh, in this priority: (1) hard dependencies, a stacked branch cannot land before its base " +
  "PR, and an infra or migration gate below must be satisfied before the PRs it applies to; " +
  "(2) verified conflicts, ordered so the fewest authors have to rebase and nobody rebases twice; " +
  "(3) risk, land the smallest and lowest-risk changes first so a red trunk has an obvious cause; " +
  "(4) contributor trust, as the tiebreak between otherwise equivalent PRs.\n\n" +
  "Trust levels for this repo, recorded by the maintainer: " + JSON.stringify(trust) + ". " +
  "high means priority in the order and the benefit of the doubt in a conflict; standard means " +
  "normal review and no priority; low means deprioritized and a stricter verification bar " +
  "(cf:code-review plus a cf:change run) before it may land; blocked means it never enters the " +
  "auto-merge path and waits for a human. An author with no recorded level is treated as standard.\n\n" +
  "Actions: merge means it is ready as-is; rebase_then_merge means it needs to be rebased on " +
  trunk + " or on an earlier PR in this order first, and say which in the rationale; hold means it " +
  "should not land in this sweep, say what would unblock it; needs_human means the call is not " +
  "one an agent should make. Use warnAuthor when someone should be told before they lose time, " +
  "for example when their PR is doomed to conflict with one landing ahead of it.\n\n" +
  "Sweep mode: " + mode + ". Protected branches (out of scope as merge targets for this sweep " +
  "except " + trunk + " itself): " + protectedBranches.join(", ") + ".\n\n" +
  "PR facts:\n" + JSON.stringify(facts.map((f) => ({
    number: f.number,
    title: f.title,
    author: f.author,
    trust: trustOf(f.author),
    headRef: f.headRef,
    isDraft: f.isDraft,
    ciState: f.ciState,
    failingChecks: f.failingChecks,
    behindTrunk: f.behindTrunk,
    stackedOn: f.stackedOn,
    changedFileCount: (f.changedFiles || []).length,
    risk: f.risk,
    summary: f.summary
  })), null, 2) +
  "\n\nVerified conflict results:\n" + JSON.stringify(conflicts, null, 2) +
  "\n\nInfrastructure and migration gates:\n" + JSON.stringify(infra, null, 2),
  { model: "opus", phase: "Order", schema: ORDER_SCHEMA }
)

// Auto-merge eligibility is decided here, not in the Order agent's prose. A
// blocked author, a red or pending CI, a draft, or a blocking infra gate are
// hard exclusions the synthesis must not be able to argue past, the same way
// cf:drive's blocking lanes override its recheck agent.
const gatedNumbers = new Set(
  (infra.gates || [])
    .filter((g) => g.severity === "blocking")
    .flatMap((g) => g.appliesTo || [])
)

const byNumber = new Map(facts.map((f) => [ f.number, f ]))
const ordered = (plan.order || []).map((entry, index) => {
  const pr = byNumber.get(entry.number) || {}
  const level = trustOf(pr.author)
  const reasons = []
  if (level === "blocked") reasons.push("author trust is blocked")
  if (pr.isDraft) reasons.push("PR is a draft")
  if (pr.ciState !== "green") reasons.push("CI is " + (pr.ciState || "unknown"))
  if (pr.gatherFailed) reasons.push("fact gathering failed")
  if (gatedNumbers.has(entry.number)) reasons.push("blocked by an infra or migration gate")
  if (entry.action === "hold" || entry.action === "needs_human") reasons.push("plan action is " + entry.action)
  return {
    ...entry,
    position: index + 1,
    author: pr.author,
    trust: level,
    requiresStrictReview: level === "low",
    autoMergeEligible: reasons.length === 0,
    blockedReasons: reasons
  }
})

const queue = ordered.filter((e) => e.autoMergeEligible)
const holds = ordered.filter((e) => !e.autoMergeEligible)

// The 640-character budget reference/report.md states for the sweep headline.
const REPORT_MAX = 640
let reportDraft = "Sweep of " + facts.length + " open feature PR(s) into " + trunk + ". Order: " +
  ordered.map((e) => "#" + e.number + " (" + e.action + ")").join(" then ") + ". " +
  queue.length + " eligible to land, " + holds.length + " held. " +
  conflicts.filter((c) => c.conflicts).length + " verified conflict(s) across " +
  overlapPairs.length + " overlapping pair(s). " +
  (infra.gates || []).length + " infra/migration gate(s). " + plan.strategy
if (reportDraft.length > REPORT_MAX) reportDraft = reportDraft.slice(0, REPORT_MAX - 3) + "..."

return {
  trunk,
  mode,
  facts,
  overlapPairs: overlapPairs.map((p) => ({ a: p.a.number, b: p.b.number, shared: p.shared })),
  conflicts,
  infra,
  plan: ordered,
  strategy: plan.strategy,
  warnings: plan.warnings || [],
  autoMergeQueue: queue.map((e) => e.number),
  holds,
  reportDraft
}
