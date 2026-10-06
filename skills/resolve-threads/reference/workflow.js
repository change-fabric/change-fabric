// cf:resolve-threads Workflow script. Pass this file's contents verbatim as
// Workflow's `script` argument; do not paraphrase, summarize, or edit it in
// transit.
//
// For maintainers: this script's own logic is documented inline below. For
// the Workflow tool's general API (agent/pipeline/parallel/phase/schema
// semantics), see https://code.claude.com/docs/en/workflows.md and the full
// signature reference at https://code.claude.com/docs/en/agent-sdk/typescript.
// This script runs in a sandboxed context with no tool access, so nothing
// here can fetch those docs at runtime; they are for a human keeping this
// script in sync with the tool's actual API.
//
// Inputs come from scripts/thread_history.rb, run by SKILL.md step 1:
// threads, priorThreads and recurrence are its output fields verbatim.
//
// Model tiers:
//   Evaluate    opus     One call per thread, low volume, high stakes: it is
//                        both the read on whether the concern is real and the
//                        decision to write code in response.
//   Root cause  opus     Runs only when recurrence fired or a verdict named an
//                        earlier fix. It decides whether a cluster's
//                        per-thread diffs are thrown away for one systemic
//                        change, or the cluster is deferred to cf:plan.
//   Apply       inherit  Mechanical reconciliation of an already-decided diff
//                        against a moving working tree.

export const meta = {
  name: "cf-resolve-threads-scope",
  description: "Evaluate every unresolved PR thread in its own worktree, find the root cause when feedback recurs, then apply accepted fixes sequentially",
  phases: [
    { title: "Evaluate", model: "opus" },
    { title: "Root cause", model: "opus" },
    { title: "Apply" }
  ]
}

const VERDICT_SCHEMA = {
  type: "object",
  properties: {
    action: { type: "string", enum: [ "fix", "wont_fix", "needs_human" ] },
    rationale: { type: "string" },
    diff: { type: "string" },
    reply: { type: "string" },
    concernClass: { type: "string" },
    siblings: {
      type: "array",
      items: {
        type: "object",
        properties: {
          path: { type: "string" },
          line: { type: "number" },
          note: { type: "string" }
        },
        required: [ "path", "note" ]
      }
    },
    recurrenceOf: { type: "array", items: { type: "string" } }
  },
  required: [ "action", "rationale", "concernClass" ]
}

const CLUSTER_SCHEMA = {
  type: "object",
  properties: {
    clusters: {
      type: "array",
      items: {
        type: "object",
        properties: {
          threadIds: { type: "array", items: { type: "string" } },
          concernClass: { type: "string" },
          sameClass: { type: "boolean" },
          rootCause: { type: "string" },
          size: { type: "string", enum: [ "in_run", "plan" ] }
        },
        required: [ "threadIds", "concernClass", "sameClass", "rootCause", "size" ]
      }
    }
  },
  required: [ "clusters" ]
}

const SYSTEMIC_SCHEMA = {
  type: "object",
  properties: {
    diff: { type: "string" },
    reply: { type: "string" },
    note: { type: "string" }
  },
  required: [ "diff", "reply" ]
}

const APPLY_SCHEMA = {
  type: "object",
  properties: {
    applied: { type: "boolean" },
    commitSha: { type: "string" },
    note: { type: "string" }
  },
  required: [ "applied", "note" ]
}

// Some hosts hand this script a JSON-encoded string instead of the parsed
// object the Workflow contract promises; tolerate both.
const scope = typeof args === "string" ? JSON.parse(args) : args

const threads = scope.threads
const priorThreads = scope.priorThreads ?? []
const recurrence = scope.recurrence ?? { fired: false, threadIds: [], paths: [] }
const repoPath = scope.repoPath
const headSha = scope.headSha
const prNumber = scope.prNumber
const prTitle = scope.prTitle
const prBody = scope.prBody

// A prior fixed thread bears on an open one only when the same reviewer
// returned to the same path: a different reviewed commit and a later
// openedAt. This is the one JS copy of thread_history.rb#returned_to?, and
// resolve_threads_workflow_test.rb runs both against the same fixtures so
// they cannot drift. A missing field never matches.
const returnedTo = (t, p) => ["path", "reviewer", "reviewedCommit", "openedAt"].every((k) => t[k] && p[k]) &&
  p.path === t.path && p.reviewer === t.reviewer && p.reviewedCommit !== t.reviewedCommit && t.openedAt > p.openedAt
const priorFor = (t) => priorThreads.filter((p) => returnedTo(t, p))
const ownRecurrence = (v) => (v.recurrenceOf ?? []).filter((id) => priorFor(v).some((p) => p.threadId === id))

function threadContext(t) {
  const convo = t.comments.map((c) => c.author + ": " + c.body).join("\n")
  const staleness = t.isOutdated
    ? "This thread's anchor line is outdated; read the file's current content, not the stored hunk."
    : "This thread's anchor line still matches the current diff."
  return "Pull request: " + prTitle + "\n\n" + prBody + "\n\nThread at " + t.path + ":" +
    t.line + " (" + staleness + ")\n\n" + convo
}

// What a single thread cannot see on its own: the rest of this run, and the
// per-instance fixes already made on the same file in earlier rounds.
function runContext(t) {
  const others = threads.filter((o) => o.threadId !== t.threadId)
    .map((o) => "- " + o.path + ":" + o.line + " " + o.title).join("\n")
  const prior = priorFor(t)
    .map((p) => "- " + p.threadId + " (fixed in " + p.fixSha + "): " + p.title).join("\n")
  return "\n\nOther unresolved threads in this run:\n" + (others || "(none)") +
    "\n\nEarlier threads by " + t.reviewer + " on " + t.path + " already fixed per instance; read each fix with " +
    "`git show <sha>` in your worktree:\n" + (prior || "(none)")
}

function worktreeSetup() {
  return "Before doing anything else, create your own throwaway checkout: run " +
    "`d=$(mktemp -d) && git -C " + repoPath + " worktree add \"$d\" " + headSha +
    " && echo \"$d\"`, then do every read and every trial edit inside that echoed path only, " +
    "never in " + repoPath + " itself. Remove it when finished with `git -C " + repoPath +
    " worktree remove \"<path>\" --force`, whether or not the change was applied there. "
}

function slugFor(concernClass) {
  const words = String(concernClass).toLowerCase().replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "").split("-").filter(Boolean).slice(0, 3)
  return "pr-" + prNumber + "-" + (words.length > 0 ? words.join("-") : "root-cause")
}

phase("Evaluate")
const verdicts = await parallel(threads.map((t) => () =>
  agent(
    worktreeSetup() +
    "Decide how to handle this review thread, reading as much of the repository as the " +
    "decision needs, not just the diff hunk: does the concern hold up against the real code, " +
    "and is it worth acting on regardless of whether a human or a bot raised it?\n\n" +
    threadContext(t) + runContext(t) +
    "\n\nBefore deciding, name the class of bug this concern is one instance of, as " +
    "concernClass: a short kebab-case phrase such as unanchored-name-regex or " +
    "declaration-boundary-scan, not a restatement of the line. Then probe for the same class " +
    "elsewhere: search this file and its subsystem for the same pattern, and read each earlier " +
    "fix listed above. A reviewer who finds one instance will find the next one in the next " +
    "round; fixing only the reported line is how a PR ends up with another round.\n\n" +
    "If the concern is real and worth fixing, fix every instance of the class you found, not " +
    "only the reported one, list each extra instance in siblings (path, line, one-line note), " +
    "and make the regression test enumerate the class's variants rather than only the reported " +
    "input. Confirm it behaves (run the relevant tests), then capture `git diff` there as the " +
    "`diff` field and set action to fix. If this concern is the same class as an earlier fixed " +
    "thread listed above, put that thread's id in recurrenceOf. If it is not worth fixing " +
    "(already covered elsewhere, based on a misreading, or the cost outweighs the benefit), set " +
    "action to wont_fix and say why in rationale. If the right call depends on a judgment this " +
    "agent cannot make (product intent, a tradeoff only a maintainer can weigh, conflicting " +
    "guidance elsewhere in the PR), set action to needs_human. Always include a short reply " +
    "meant for the thread itself.",
    { phase: "Evaluate", label: t.path + ":" + t.line, schema: VERDICT_SCHEMA }
  ).then((v) => (v ? { ...t, ...v } : { ...t, action: "needs_human", concernClass: "unknown", rationale: "evaluation agent did not return a result" }))
))

phase("Root cause")
// Keyed by thread identity, never by path: another reviewer's thread on a
// recurrent path is not that reviewer returning, so it keeps its own verdict.
const recurrentIds = new Set(recurrence.fired ? (recurrence.threadIds ?? []) : [])
const candidates = verdicts.filter((v) => v.action !== "wont_fix" &&
  (recurrentIds.has(v.threadId) || ownRecurrence(v).length > 0))
const byId = new Map(verdicts.map((v) => [ v.threadId, v ]))
// Only fix verdicts may land unattended: a cluster holding any needs_human
// (or missing) verdict goes to the interactive plan path, never in_run.
const clusterSize = (size, members) => (size === "in_run" && members.length > 0 && members.every((v) => Boolean(v) && v.action === "fix") ? "in_run" : "plan")
let clusters = []
if (candidates.length > 0) {
  const summary = candidates.map((v) => ({
    threadId: v.threadId, path: v.path, line: v.line, title: v.title,
    concernClass: v.concernClass, rationale: v.rationale,
    siblings: v.siblings ?? [], recurrenceOf: ownRecurrence(v)
  }))
  const map = await agent(
    "Review feedback on this pull request is recurring: the same reviewer came back on a new " +
    "head commit and flagged more problems on files where earlier threads were already fixed " +
    "one instance at a time. Find the root cause instead of another instance fix. Read the " +
    "repository at " + repoPath + " (read only; do not edit it) and each earlier fix with " +
    "`git -C " + repoPath + " show <sha>`.\n\nPull request: " + prTitle + "\n\n" + prBody +
    "\n\nRecurring candidate threads (current round):\n" + JSON.stringify(summary, null, 2) +
    "\n\nEarlier per-instance fixes:\n" + JSON.stringify(priorThreads, null, 2) +
    "\n\nGroup the candidate threads into clusters that share ONE root cause. Set sameClass " +
    "false for a group that merely sits in the same file without a shared cause; those threads " +
    "keep their own verdicts. Write rootCause as one plain sentence a reviewer would accept. " +
    "Size each cluster: in_run when one coherent change of modest size fixes the cause inside " +
    "the existing design (one subsystem, no new module, one commit a reviewer can read); plan " +
    "when the honest fix is a redesign (a real parser instead of regex scanning, a new module " +
    "boundary, changes across subsystems, a migration). Use only threadIds from the list above, " +
    "and put each thread in at most one cluster.",
    { model: "opus", phase: "Root cause", schema: CLUSTER_SCHEMA }
  )
  const known = new Set(candidates.map((v) => v.threadId))
  const taken = new Set()
  for (const c of (map?.clusters ?? [])) {
    const ids = (c.threadIds ?? []).filter((id) => known.has(id) && !taken.has(id))
    if (!c.sameClass || ids.length === 0) continue
    ids.forEach((id) => taken.add(id))
    clusters.push({ ...c, threadIds: ids, size: clusterSize(c.size, ids.map((id) => byId.get(id))) })
  }
  // A null root-cause map, and any candidate the map left out (a cluster
  // marked sameClass false, or simply omitted), never falls back to a
  // per-instance fix: it becomes (or joins) one generic plan cluster so the
  // recurrence still reaches cf:plan instead of landing unattended.
  const unaccounted = candidates.filter((v) => !taken.has(v.threadId))
  if (unaccounted.length > 0) {
    const files = [ ...new Set(unaccounted.map((v) => v.path)) ].join(", ")
    clusters.push({
      threadIds: unaccounted.map((v) => v.threadId),
      concernClass: "unidentified",
      sameClass: true,
      rootCause: "Recurring review findings on " + files + " share an unidentified root cause; " +
        "find it and fix the class, not the instances.",
      size: "plan"
    })
  }
  const inRun = clusters.filter((c) => c.size === "in_run")
  const systemic = await parallel(inRun.map((c) => () =>
    agent(
      worktreeSetup() +
      "Fix this root cause as one systemic change in your worktree, replacing the per-thread " +
      "fixes below. Cover every thread in the cluster and every sibling instance they name, " +
      "and add a regression test that enumerates the class's variants. Run the relevant tests. " +
      "Capture `git diff` as diff. Write reply as one plain sentence naming the root cause; " +
      "every thread in the cluster will cite it.\n\nRoot cause (" + c.concernClass + "): " +
      c.rootCause + "\n\nThreads and their per-thread verdicts:\n" +
      JSON.stringify(c.threadIds.map((id) => byId.get(id)), null, 2),
      { model: "opus", phase: "Root cause", label: c.concernClass, schema: SYSTEMIC_SCHEMA }
    )
  ))
  // An in-run cluster with no systemic diff (agent null, or empty diff)
  // converts to a plan cluster instead of dissolving: its threads keep the
  // root cause they were grouped under and still reach cf:plan, rather than
  // falling back to a per-instance fix that was already rejected once.
  inRun.forEach((c, i) => {
    const s = systemic[i]
    if (s && s.diff) {
      c.diff = s.diff
      c.reply = s.reply
    } else {
      c.size = "plan"
    }
  })
}

phase("Apply")
const clustered = new Set(clusters.flatMap((c) => c.threadIds))
const clusterApplied = []
for (const c of clusters.filter((k) => k.size === "in_run")) {
  const result = await agent(
    "In the repository at " + repoPath + " (already checked out on the branch under review), " +
    "apply this systemic fix for the root cause " + c.concernClass + ".\n\nDiff captured from " +
    "an isolated trial:\n\n" + c.diff + "\n\nTry to apply it as-is first; if it no longer " +
    "applies cleanly because an earlier fix in this same run touched overlapping code, re-read " +
    "the current files and re-implement the equivalent change by hand instead of forcing the " +
    "patch. Create exactly one commit for the whole cluster, its message naming the root cause " +
    "and every file it touches, then report the commit sha by running `git rev-parse HEAD` and " +
    "copying its output verbatim; never guess or recall a sha from memory. If the change cannot " +
    "be reconciled with what is already on disk, make no commit and report why.",
    { phase: "Apply", label: c.concernClass, schema: APPLY_SCHEMA }
  )
  clusterApplied.push({ ...c, ...(result || { applied: false, note: "apply agent did not return a result" }) })
}

const toApply = verdicts.filter((v) => v.action === "fix" && v.diff && !clustered.has(v.threadId))
const applied = []
for (const v of toApply) {
  const result = await agent(
    "In the repository at " + repoPath + " (already checked out on the branch under review), " +
    "apply this fix for the review thread at " + v.path + ":" + v.line + ".\n\nDiff captured " +
    "from an isolated trial:\n\n" + v.diff + "\n\nTry to apply it as-is first; if it no longer " +
    "applies cleanly because an earlier fix in this same run touched overlapping code, re-read " +
    "the current file and re-implement the equivalent change by hand instead of forcing the " +
    "patch. Once the working tree has the change, create exactly one commit for it referencing " +
    v.path + " and the concern it addresses, then report the commit sha by running `git rev-parse HEAD` " +
    "and copying its output verbatim; never guess or recall a sha from memory. If the change cannot be " +
    "reconciled with what is already on disk, make no commit and report why.",
    { phase: "Apply", label: v.path + ":" + v.line, schema: APPLY_SCHEMA }
  )
  applied.push({ ...v, ...(result || { applied: false, note: "apply agent did not return a result" }) })
}

const threadRef = (id) => {
  const v = byId.get(id)
  return { threadId: id, path: v.path, line: v.line, commentId: v.commentId, title: v.title }
}
// Only an apply result that is both applied and carries a well-formed commit
// sha has landed: the caller replies `Fixed in <sha>.` and resolves every
// thread it returns as fixed or as an in-run cluster. Every other result
// (applied false, a missing result, or applied with no sha, or a sha that is
// not 7-40 hex characters) is a conflict, so one predicate routes both the
// per-thread and the cluster results. The Apply agent cannot run git itself
// to verify a commit, so this script trusts nothing past syntactic shape;
// the caller's own `git merge-base --is-ancestor` check after push is what
// actually confirms the commit landed (see SKILL.md).
const COMMIT_SHA_RE = /^[0-9a-f]{7,40}$/
const landed = (r) => Boolean(r && r.applied && r.commitSha && COMMIT_SHA_RE.test(r.commitSha))
const inRunClusters = clusterApplied
  .filter(landed)
  .map((c) => ({
    concernClass: c.concernClass, rootCause: c.rootCause, reply: c.reply,
    applied: c.applied, commitSha: c.commitSha, note: c.note, threads: c.threadIds.map(threadRef)
  }))
const clusterConflicts = clusterApplied
  .filter((c) => !landed(c))
  .flatMap((c) => c.threadIds.map((id) => ({
    ...threadRef(id), applied: false,
    note: c.note || (c.applied ? "cluster reported applied with no commit sha" : "cluster fix did not land")
  })))
const planClusters = clusters.filter((c) => c.size === "plan").map((c) => ({
  concernClass: c.concernClass, rootCause: c.rootCause, threads: c.threadIds.map(threadRef)
}))

let plan = null
if (planClusters.length > 0) {
  const lead = planClusters.reduce((a, b) => (b.threads.length > a.threads.length ? b : a))
  const slug = slugFor(lead.concernClass)
  const sections = planClusters.map((c) =>
    "Class " + c.concernClass + ": " + c.rootCause.replace(/[.\s]*$/, ".") + " Threads: " +
    c.threads.map((t) => t.path + ":" + t.line + " " + t.title).join("; ") + ".").join(" ")
  const shas = priorThreads.filter((p) => planClusters.some((c) => c.threads.some((t) => priorFor(byId.get(t.threadId)).includes(p))))
    .map((p) => p.fixSha)
  const seededGoal = "Root-cause fix for recurring review feedback on PR #" + prNumber + " (" +
    prTitle + "). The same reviewer keeps returning to the same files after per-instance fixes. " +
    sections + " Prior per-instance fixes: " + (shas.join(", ") || "none") + ". Plan the " +
    "systemic fix, not another instance patch. Use slug " + slug + "."
  plan = { slug: slug, seededGoal: seededGoal, threadIds: planClusters.flatMap((c) => c.threads.map((t) => t.threadId)) }
}

const fixed = applied.filter(landed)
const conflicts = applied.filter((a) => !landed(a)).concat(clusterConflicts)
const wontFix = verdicts.filter((v) => v.action === "wont_fix" && !clustered.has(v.threadId))
// A fix verdict with no diff never had a trial change to apply; it is not
// in no bucket, it needs a human, same as an explicit needs_human verdict.
const fixNoDiff = verdicts.filter((v) => v.action === "fix" && !v.diff && !clustered.has(v.threadId))
  .map((v) => ({ ...v, rationale: "fix verdict carried no diff" }))
const needsHuman = verdicts.filter((v) => v.action === "needs_human" && !clustered.has(v.threadId))
  .concat(fixNoDiff)

return { fixed, wontFix, needsHuman, conflicts, clusters: inRunClusters, planClusters, plan, recurrence }
