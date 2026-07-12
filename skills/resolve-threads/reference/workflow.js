// pst:resolve-threads Workflow script. Pass this file's contents verbatim as
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
// Model tiers:
//   Evaluate  opus     One call per thread, low volume, high stakes: it is
//                      both the read on whether the concern is real and the
//                      decision to write code in response.
//   Apply     inherit  Mechanical reconciliation of an already-decided diff
//                      against a moving working tree.

export const meta = {
  name: "pst-resolve-threads-scope",
  description: "Evaluate every unresolved PR thread in its own worktree, then apply accepted fixes sequentially",
  phases: [
    { title: "Evaluate", model: "opus" },
    { title: "Apply" }
  ]
}

const VERDICT_SCHEMA = {
  type: "object",
  properties: {
    action: { type: "string", enum: [ "fix", "wont_fix", "needs_human" ] },
    rationale: { type: "string" },
    diff: { type: "string" },
    reply: { type: "string" }
  },
  required: [ "action", "rationale" ]
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
const repoPath = scope.repoPath
const headSha = scope.headSha
const prTitle = scope.prTitle
const prBody = scope.prBody

function threadContext(t) {
  const convo = t.comments.map((c) => c.author + ": " + c.body).join("\n")
  const staleness = t.isOutdated
    ? "This thread's anchor line is outdated; read the file's current content, not the stored hunk."
    : "This thread's anchor line still matches the current diff."
  return "Pull request: " + prTitle + "\n\n" + prBody + "\n\nThread at " + t.path + ":" +
    t.line + " (" + staleness + ")\n\n" + convo
}

function worktreeSetup() {
  return "Before doing anything else, create your own throwaway checkout: run " +
    "`git -C " + repoPath + " worktree add $(mktemp -d) " + headSha + "` and note the " +
    "path it prints, then do every read and every trial edit inside that path only, " +
    "never in " + repoPath + " itself. Remove it when finished with `git -C " + repoPath +
    " worktree remove <path> --force`, whether or not the change was applied there. "
}

phase("Evaluate")
const verdicts = await parallel(threads.map((t) => () =>
  agent(
    worktreeSetup() +
    "Decide how to handle this review thread, reading as much of the repository as the " +
    "decision needs, not just the diff hunk: does the concern hold up against the real code, " +
    "and is it worth acting on regardless of whether a human or a bot raised it?\n\n" +
    threadContext(t) +
    "\n\nIf the concern is real and worth fixing, make the change in your worktree, confirm " +
    "it behaves (a quick test or a manual check), then capture `git diff` there as the `diff` " +
    "field and set action to fix. If it is not worth fixing (already covered elsewhere, " +
    "based on a misreading, or the cost outweighs the benefit), set action to wont_fix and say " +
    "why in rationale. If the right call depends on a judgment this agent cannot make (product " +
    "intent, a tradeoff only a maintainer can weigh, conflicting guidance elsewhere in the PR), " +
    "set action to needs_human. Always include a short reply meant for the thread itself.",
    { phase: "Evaluate", label: t.path + ":" + t.line, schema: VERDICT_SCHEMA }
  ).then((v) => (v ? { ...t, ...v } : { ...t, action: "needs_human", rationale: "evaluation agent did not return a result" }))
))

phase("Apply")
const toApply = verdicts.filter((v) => v.action === "fix" && v.diff)
const applied = []
for (const v of toApply) {
  const result = await agent(
    "In the repository at " + repoPath + " (already checked out on the branch under review), " +
    "apply this fix for the review thread at " + v.path + ":" + v.line + ".\n\nDiff captured " +
    "from an isolated trial:\n\n" + v.diff + "\n\nTry to apply it as-is first; if it no longer " +
    "applies cleanly because an earlier fix in this same run touched overlapping code, re-read " +
    "the current file and re-implement the equivalent change by hand instead of forcing the " +
    "patch. Once the working tree has the change, create exactly one commit for it referencing " +
    v.path + " and the concern it addresses, and report the commit sha. If the change cannot be " +
    "reconciled with what is already on disk, make no commit and report why.",
    { phase: "Apply", label: v.path + ":" + v.line, schema: APPLY_SCHEMA }
  )
  applied.push({ ...v, ...(result || { applied: false, note: "apply agent did not return a result" }) })
}

const fixed = applied.filter((a) => a.applied)
const conflicts = applied.filter((a) => !a.applied)
const wontFix = verdicts.filter((v) => v.action === "wont_fix")
const needsHuman = verdicts.filter((v) => v.action === "needs_human")

return { fixed, wontFix, needsHuman, conflicts }
