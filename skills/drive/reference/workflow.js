// pst:drive Workflow script. Pass this file's contents verbatim as
// Workflow's `script` argument; do not paraphrase, summarize, or edit it in
// transit. It owns the local quality-and-CI engine SKILL.md's steps 3-7
// describe by hand: relevance-gating the two optional lanes, iterating the
// selected lanes to a would-approve state, and predicting CI locally. The
// thread sweeps, the checkpoints, the push, the CI poll, and the approval
// stay outside it (SKILL.md's steps 2, 6b, 8-12), since those need either a
// GitHub tool or a human ask this script has no way to make.
//
// For maintainers: this script's own logic is documented inline below. For
// the Workflow tool's general API (agent/pipeline/parallel/phase/schema
// semantics), see https://code.claude.com/docs/en/workflows.md and the full
// signature reference at https://code.claude.com/docs/en/agent-sdk/typescript.
// This script runs in a sandboxed context with no tool access, so nothing
// here can fetch those docs at runtime, and none of the git/bash/test work
// below happens directly in this script either; every `agent()` call is a
// real sub-agent with tool access that does the actual worktree, bash, and
// test work on its behalf.
//
// Model tiers:
//   Relevance   haiku   High-volume, mechanically bounded: decide two
//                       booleans from a route summary and a file list.
//   Quality     inherit Lane agents write real fixes; needs full reasoning.
//   Recheck     opus    Low volume, highest stakes: gates the push.
//   Predict CI  inherit Runs and reads real command output; no rubric to
//                       delegate to a cheaper tier.

export const meta = {
  name: "pst-drive-quality-and-ci",
  description: "Relevance-gate quality lanes, iterate fixes to a would-approve state, then predict CI locally",
  phases: [
    { title: "Relevance", model: "haiku" },
    { title: "Quality" },
    { title: "Recheck", model: "opus" },
    { title: "Predict CI" }
  ]
}

const RELEVANCE_SCHEMA = {
  type: "object",
  properties: {
    qa: {
      type: "object",
      properties: { relevant: { type: "boolean" }, rationale: { type: "string" } },
      required: [ "relevant", "rationale" ]
    },
    refactor: {
      type: "object",
      properties: { relevant: { type: "boolean" }, rationale: { type: "string" } },
      required: [ "relevant", "rationale" ]
    }
  },
  required: [ "qa", "refactor" ]
}

const LANE_SCHEMA = {
  type: "object",
  properties: {
    fixed: { type: "number" },
    deferred: { type: "number" },
    notes: { type: "string" },
    blocking: { type: "boolean" }
  },
  required: [ "fixed", "deferred", "blocking", "notes" ]
}

const RECHECK_SCHEMA = {
  type: "object",
  properties: { wouldApprove: { type: "boolean" }, rationale: { type: "string" } },
  required: [ "wouldApprove", "rationale" ]
}

const CI_SCHEMA = {
  type: "object",
  properties: {
    green: { type: "boolean" },
    jobs: {
      type: "array",
      items: {
        type: "object",
        properties: {
          name: { type: "string" },
          command: { type: "string" },
          passed: { type: "boolean" },
          evidence: { type: "string" }
        },
        required: [ "name", "passed", "evidence" ]
      }
    }
  },
  required: [ "green", "jobs" ]
}

// Some hosts hand this script a JSON-encoded string instead of the parsed
// object the Workflow contract promises; tolerate both.
const scope = typeof args === "string" ? JSON.parse(args) : args

const files = scope.files
const repoPath = scope.repoPath
const headSha = scope.headSha
const routeOutput = scope.routeOutput
const isPR = Boolean(scope.isPR)
const cap = scope.cap ?? 4
const ciFixContext = scope.ciFixContext ?? null

// isolation: "worktree" on the Agent calls below only isolates this
// session's own primary repo, not repoPath, so it is not used here. Every
// lane and recheck call manages its own git worktree of repoPath instead,
// which is correct whether repoPath is the primary repo or a separate one.
function worktreeSetup() {
  return "Before exploring or verifying anything, create a throwaway checkout: run " +
    "`d=$(mktemp -d) && git -C " + repoPath + " worktree add \"$d\" " + headSha +
    " && echo \"$d\"`, then do reads and trial verification inside that echoed path. " +
    "Fixes you decide to keep must land in " + repoPath + " itself, not just the worktree, " +
    "since that is the tree that gets committed and pushed. Remove the worktree when done " +
    "with `git -C " + repoPath + " worktree remove \"<path>\" --force`. "
}

phase("Relevance")
const relevance = await agent(
  "Two pst quality lanes, pst:qa and pst:refactor, are gated on relevance to this change; " +
  "decide each independently. pst:code-review and pst:ai-slop are not part of this decision, " +
  "they run unconditionally regardless of what you say here.\n\n" +
  "qa.relevant should be true when the change touches a user-facing or browser-drivable " +
  "surface, or when the route summary below lists a UI rubric (pst:react, pst:nextjs, " +
  "pst:client-state, pst:vite). A change with no reachable UI or flow to smoke-test should " +
  "get qa.relevant: false.\n\n" +
  "refactor.relevant should be true when the route summary lists any matched skill other than " +
  "pst:ai-slop alone. A pure-docs change whose only route hit is pst:ai-slop should get " +
  "refactor.relevant: false; there is no code shape to refactor.\n\n" +
  "Files:\n" + files.join("\n") + "\n\nRoute output (ruby skill_route.rb):\n" + routeOutput,
  { model: "haiku", phase: "Relevance", schema: RELEVANCE_SCHEMA }
)

// pst:ai-slop's own frontmatter is `auto: all_files: true`, matching every
// file unconditionally; gating it on a relevance call would just replay
// that same always-true answer through an extra agent call. pst:code-review
// is the other floor: correctness and refactor-opportunity coverage a
// change of any size should get, not something a relevance guess should be
// allowed to skip.
const selectedSkills = [ "pst:code-review", "pst:ai-slop" ]
if (relevance.qa.relevant) selectedSkills.push("pst:qa")
if (relevance.refactor.relevant) selectedSkills.push("pst:refactor")
log("Selected lanes: " + selectedSkills.join(", "))

function codeReviewPrompt() {
  return worktreeSetup() +
    "Review these files for correctness bugs, security issues, missing or wrong test " +
    "coverage, and refactor opportunities. Apply the matched skill rubrics from the route " +
    "output below where they cover a file, plus general judgment where they do not. Verify " +
    "each candidate finding by reproducing it in the worktree (a failing test or an actual " +
    "invocation), not by re-reading the code and agreeing. Fix every confirmed issue directly " +
    "in " + repoPath + " rather than posting comments about it.\n\nFiles:\n" + files.join("\n") +
    "\n\nRoute output:\n" + routeOutput
}

function aiSlopPrompt() {
  return "Apply the pst:ai-slop rubric to every changed file: no filler, no em-dash, no " +
    "bullet glyph other than markdown '-'/'*', no ellipsis glyph, no smart quotes, no agent " +
    "attribution footers, self-documenting code, comments only for why not what. Fix " +
    "violations directly in " + repoPath + ".\n\nFiles:\n" + files.join("\n")
}

function qaPrompt() {
  return "Scope a Playwright smoke-test plan for this change per pst:qa's own approach: an " +
    "ephemeral browserless Chromium container, a digest-pinned image, never a host daemon. " +
    "Execute the plan against the app under test. Fix anything code-fixable that the flows " +
    "surface directly in " + repoPath + "; report anything else as a deferred finding.\n\n" +
    "Files:\n" + files.join("\n")
}

function refactorPrompt() {
  return worktreeSetup() +
    "Route these files through the applicable pst skill rubrics via the route output below. " +
    "For each smell found, apply the smallest behavior-preserving refactor, then verify with " +
    "the repo's tests or build. Apply confirmed refactors directly in " + repoPath + ".\n\n" +
    "Files:\n" + files.join("\n") + "\n\nRoute output:\n" + routeOutput
}

const lanePrompts = {
  "pst:code-review": codeReviewPrompt,
  "pst:ai-slop": aiSlopPrompt,
  "pst:qa": qaPrompt,
  "pst:refactor": refactorPrompt
}

phase("Quality")
const iterations = []
let converged = false
for (let n = 1; n <= cap; n++) {
  // Lanes run sequentially, not in parallel, within one iteration: every
  // lane can write to the same repoPath, and parallel writes would collide.
  // This mirrors pst:resolve-threads' own sequential Apply phase for the
  // same reason (its Evaluate phase parallelizes because worktrees isolate
  // it; its Apply phase, which touches the shared repoPath, does not).
  const lanesRun = []
  for (const skill of selectedSkills) {
    const result = await agent(
      lanePrompts[skill](),
      { phase: "Quality", label: "iteration " + n + ":" + skill, schema: LANE_SCHEMA }
    )
    lanesRun.push({ skill, ...(result || { fixed: 0, deferred: 0, blocking: true, notes: skill + " lane returned no result" }) })
  }

  phase("Recheck")
  // A lane reporting blocking: true (including the no-result fallback above)
  // must not be overridable by the recheck agent's own read of the diff; it
  // is a hard gate, not just prose folded into the recheck prompt.
  const blockingLanes = lanesRun.filter((l) => l.blocking)
  const recheck = blockingLanes.length > 0
    ? {
        wouldApprove: false,
        rationale: "blocked by " + blockingLanes.map((l) => l.skill + ": " + l.notes).join("; ")
      }
    : await agent(
        "Inspect the current state of " + repoPath + " (the real working tree; every fix this " +
        "iteration decided to keep is already applied there, not left in a worktree). Would this " +
        "change earn a real pull request approval right now? Weigh the lane notes below alongside " +
        "your own read of the diff.\n\nLane results this iteration:\n" +
        JSON.stringify(lanesRun, null, 2),
        { model: "opus", phase: "Recheck", label: "iteration " + n, schema: RECHECK_SCHEMA }
      )

  iterations.push({
    n,
    lanesRun,
    fixed: lanesRun.reduce((sum, l) => sum + (l.fixed || 0), 0),
    deferred: lanesRun.reduce((sum, l) => sum + (l.deferred || 0), 0),
    wouldApprove: Boolean(recheck && recheck.wouldApprove),
    recheckRationale: recheck ? recheck.rationale : "recheck agent returned no result"
  })

  if (recheck && recheck.wouldApprove) {
    converged = true
    break
  }
}

phase("Predict CI")
// Runs directly against repoPath rather than a fresh worktree: by this
// point every kept fix from the Quality/Recheck loop above is already
// committed to the live tree, and CI prediction needs to see exactly that
// state, not a snapshot from headSha that predates the fixes.
async function predictCI() {
  return agent(
    "In the repository at " + repoPath + ", read every workflow file under " +
    ".github/workflows/*.yml. For each job, extract its real setup steps (dependency install, " +
    "toolchain setup) and its real test/lint/typecheck/build commands, exactly as written, " +
    "not assumed from convention. Run each job's setup then its commands locally in " +
    repoPath + " and report per-job pass or fail with concrete evidence (the actual output or " +
    "exit code), not a guess. This repository's own CI shape is not special-cased; read " +
    "whatever workflow files are actually present and run whatever they actually say.",
    { phase: "Predict CI", schema: CI_SCHEMA }
  )
}

if (ciFixContext) {
  await agent(
    "CI failed on the pushed commit for these jobs:\n" +
    JSON.stringify(ciFixContext.failingJobs, null, 2) +
    "\n\nLogs:\n" + ciFixContext.logs +
    "\n\nFix exactly these failures in " + repoPath + ". Do not touch unrelated code.",
    { phase: "Predict CI", label: "ci-fix" }
  )
}

const ciPrediction = await predictCI()

const fixesSummary = "Across " + iterations.length + " iteration(s): " +
  iterations.map((it) => "iteration " + it.n + " (" + it.lanesRun.map((l) => l.skill).join(", ") +
    ") fixed " + it.fixed + ", deferred " + it.deferred).join("; ") +
  ". " + (converged ? "Would-approve reached." : "Iteration cap reached without a would-approve verdict.")

const totalFixed = iterations.reduce((sum, it) => sum + it.fixed, 0)
const totalDeferred = iterations.reduce((sum, it) => sum + it.deferred, 0)
const ciNote = ciPrediction && ciPrediction.green ? "local CI prediction green" : "local CI prediction not green"
let execSummaryDraft = "Lanes: " + selectedSkills.join(", ") + ". Fixed " + totalFixed +
  ", deferred " + totalDeferred + " across " + iterations.length + " iteration(s), " +
  (converged ? "reached would-approve" : "cap reached without would-approve") + ". " + ciNote +
  ". Thread sweeps: {{threadSweeps}}"
if (execSummaryDraft.length > 640) execSummaryDraft = execSummaryDraft.slice(0, 637) + "..."

return {
  selectedSkills,
  routeSummary: routeOutput,
  relevance,
  iterations,
  converged,
  iterationCap: cap,
  ciPrediction,
  fixesSummary,
  execSummaryDraft
}
