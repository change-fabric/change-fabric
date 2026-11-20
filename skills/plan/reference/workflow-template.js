// Template for the `workflow.js` that cf:plan lands beside plan.md and
// goal.md. The writing agent instantiates this: replace every ALL-CAPS
// placeholder and every phase with the plan's own, delete what the plan does
// not need, and keep the structure. Do not ship this file as-is; a workflow
// whose phases are "Phase 1, Phase 2" has not been written, only copied.
//
// The executing session passes the instantiated file's contents verbatim as
// Workflow's `script` argument. For the Workflow tool's general API
// (agent/pipeline/parallel/phase/schema semantics) see
// https://code.claude.com/docs/en/workflows.md and the signature reference at
// https://code.claude.com/docs/en/agent-sdk/typescript. This repo's own
// hand-written examples are skills/drive/reference/workflow.js,
// skills/code-review/reference/workflow.js, skills/sweep/reference/workflow.js,
// and skills/resolve-threads/reference/workflow.js; read one before authoring.
//
// Authoring contract, in the order it bites:
//
//  1. `export const meta = {...}` must be a literal object at the top level.
//     It is read statically, before the script runs, so no variables, no
//     spreads, no computed keys. Every `title` in `meta.phases` must match a
//     `phase("...")` call exactly, including case.
//  2. The script runs in a sandbox with NO tool access. It cannot read a file,
//     run a command, or call git. Every piece of real work happens inside an
//     `agent()` call, which is a real sub-agent that does have tools. If the
//     script itself seems to need a shell, the design is wrong.
//  3. Deterministic prelude. No wall-clock reads, no randomness, no ambient
//     mutable state: nothing from the Date constructor, Date's now, or Math's
//     random. The prelude is re-executed on resume, and a value that differs
//     between executions silently changes the run. plan_check.rb greps for
//     the literal call syntax and fails the plan, so it must not appear even
//     in a comment.
//  4. `args` is the only input. It arrives as an object or a JSON string;
//     normalize once at the top, and default every optional field.
//  5. `agent()` is awaited and returns the value its `schema` describes.
//     Declare a schema wherever the result drives control flow, so a
//     malformed answer fails loudly instead of steering the run.
//  6. Return a single object at the end. That is the workflow's result and
//     the only thing the calling session sees.
//  7. Keep the resource gate. `gate()` runs as the first thing after Phase 0's
//     `phase("Resource floors")`, as the first statement after
//     `phase(spec.title)` in the PHASES loop, and as the statement right before
//     every `parallel(` (a guard `if (!g || !g.ok) {...}` may sit between the
//     gate and the `parallel(`). Declare FANOUT literally: one batch per
//     `parallel()` block, `[{op, count}]` each. plan_check.rb runs
//     scripts/resource_gate_lint.rb and fails a script whose gate is missing,
//     late, commented out or after a return.
//
// Model roles: pick per call. The classifier role for high-volume mechanically
// bounded classification, the critic role for the low volume, high stakes calls
// that gate everything downstream, the worker role for an agent that executes a
// bounded phase or reads real output. Always set `model` explicitly.

export const meta = {
  name: "PLAN-SLUG",
  description: "ONE LINE, WHAT THIS BUILD DOES, TAKEN FROM goal.md",
  phases: [
    { title: "Resource floors" },
    { title: "PHASE ONE TITLE" },
    { title: "PHASE TWO TITLE" },
    { title: "Verify" }
  ]
}

// Everything the plan fixed at authoring time. Constants here, not inline, so
// the executing session can see what the plan decided at a glance. Both use
// '~' for the home directory, never the literal absolute path: the plan may
// be carried (rsync or similar) to a machine where the same account's home
// sits under a different literal path (/Users/pxt vs /home/exe vs
// /Users/PST), and every use below is inside a natural-language agent()
// prompt, where a tool with shell access (Bash) expands '~' the normal way. A
// tool that needs a literal absolute path (Read, Write) cannot use '~'
// directly; the agent expands it against its own home first.
const REPO_PATH = "~/HOME-RELATIVE REPO PATH FROM THE PLAN"
const PLAN_PATH = "~/HOME-RELATIVE plan.md PATH"

// Fan-out declaration, literal. One batch per parallel() block: the heavy ops
// that run at the same time, as [{op, count}]. Separate batches run one after
// another. `worktrees` is how many worktrees the plan keeps live at once. The
// batch named "phase" is the PHASES loop (one phase agent at a time). Ops are
// the names the probe records (rake_test, change_boot, change_lanes, ...).
const FANOUT = { worktrees: 1, batches: { phase: [{ op: "rake_test", count: 1 }] } }

// Declare a schema wherever a result drives control flow.
const PHASE_SCHEMA = {
  type: "object",
  properties: {
    landed: { type: "boolean" },
    files: { type: "array", items: { type: "string" } },
    verification: { type: "string" },
    notes: { type: "string" }
  },
  required: [ "landed", "files", "verification" ]
}

// Mirrors the JSON of `scripts/resource_gate.rb check --json`.
const GATE_SCHEMA = {
  type: "object",
  properties: {
    ok: { type: "boolean" },
    ram_available_mb: { type: "number" },
    disk_free_gb: { type: "number" },
    need: { type: "object" },
    reclaimed: { type: "object" },
    candidates: { type: "array", items: { type: "object" } },
    provisional: { type: "boolean" }
  },
  required: [ "ok", "ram_available_mb", "disk_free_gb", "need", "reclaimed", "candidates", "provisional" ]
}

const input = typeof args === "string" ? JSON.parse(args) : (args ?? {})
const stopOnFailure = input.stopOnFailure ?? true
// Optional list of phase titles to run. Empty (the default) runs every phase
// end to end; a non-empty list runs only the named phases, which is how a
// caller who asked to be checked in with runs one phase at a time.
const only = Array.isArray(input.only) ? input.only : []

// The resource gate. The script has no tools, so an agent runs the CLI and
// returns its JSON verbatim. Tier 1 reclaim is automatic; tier 2 comes back as
// ok:false with candidates and the executing session asks the user.
async function gate(where, batchName) {
  const batch = FANOUT.batches[batchName].map((b) => b.op + ":" + b.count).join(",")
  return await agent(
    "Resource gate at: " + where + ". Repository: " + REPO_PATH + " ('~' is your home; " +
    "expand it for tools that need a literal path).\n\n" +
    "From the repo root run exactly:\n" +
    "ruby scripts/resource_gate.rb check --json --reclaim-safe --batch " + batch +
    " --worktrees " + FANOUT.worktrees + "\n" +
    "and return its JSON verbatim. If the command is missing or exits 4, return ok false " +
    "with the failure in need. Never delete anything beyond what the command itself does, " +
    "and never touch other projects' containers or credentials.",
    { model: {{model-js:classifier}}, phase: "Resource floors", label: "gate: " + where, schema: GATE_SCHEMA }
  )
}

// Common preamble for every phase agent. The plan is the source of truth, so
// each agent reads it rather than trusting a paraphrase in this script.
function preamble(phaseName) {
  return "You are executing one phase of a plan that is already settled. " +
    PLAN_PATH + " and " + REPO_PATH + " below use '~' for the home directory; " +
    "expand it against your own home before passing either to a tool that " +
    "needs a literal absolute path. Read " + PLAN_PATH +
    " first, in full, then do only the phase named below. The plan's " +
    "\"Decisions (settled, do not re-litigate)\" section records answers the user " +
    "already gave; treat those as fixed and do not reopen them.\n\n" +
    "Before any heavy step (test suite, docker build, change boot or lanes), run the " +
    "resource gate: ruby scripts/resource_gate.rb check --json --reclaim-safe. If it " +
    "reports ok false, stop, set landed false, and put the gate JSON in notes.\n\n" +
    "Repository: " + REPO_PATH + "\n" +
    "Phase: " + phaseName + "\n\n"
}

// One entry per phase in the plan. Keep them in the plan's own order: the
// plan orders phases so each one leaves the tree working.
const PHASES = [
  {
    title: "PHASE ONE TITLE",
    instruction: "WHAT THIS PHASE BUILDS, IN THE PLAN'S OWN TERMS. Name the files it " +
      "creates or edits. Name the command that proves it landed.",
    verify: "THE ACTUAL TEST, BUILD, OR CHECK COMMAND FROM THE PLAN"
  },
  {
    title: "PHASE TWO TITLE",
    instruction: "SECOND PHASE. Depends on the first, so it runs after it.",
    verify: "THE ACTUAL COMMAND"
  }
]

const results = []
let stoppedBy = null

// Phase 0: resource floors before any work. Tier 2 reclaim is the user's call,
// so a failed gate returns early and the executing session asks.
if (only.length === 0 || only.includes("Resource floors")) {
  phase("Resource floors")
  const first = await gate("Phase 0", "phase")
  if (!first || !first.ok) {
    log("Stopping: below resource floor at Phase 0")
    return { plan: PLAN_PATH, stopped: "resource-floor", gate: first, phases: results }
  }
}

for (const spec of PHASES) {
  if (only.length > 0 && !only.includes(spec.title)) continue
  phase(spec.title)
  const g = await gate("start of " + spec.title, "phase")
  if (!g || !g.ok) {
    stoppedBy = { phase: spec.title, gate: g }
    log("Stopping: below resource floor at " + spec.title)
    break
  }
  const result = await agent(
    preamble(spec.title) + spec.instruction +
    "\n\nWhen the work is done, run this and report its real output, do not assume it:\n" +
    spec.verify +
    "\n\nSet landed: false if the verification did not pass. Do not report a phase " +
    "landed on the strength of the code looking right.",
    { model: {{model-js:worker}}, phase: spec.title, schema: PHASE_SCHEMA }
  )
  results.push({ phase: spec.title, ...(result ?? { landed: false, files: [], verification: "agent returned no result" }) })
  if (stopOnFailure && !results[results.length - 1].landed) {
    log("Stopping: " + spec.title + " did not land")
    break
  }
}

// Fan out with parallel() only where the plan's units of work are genuinely
// independent, and fan back in to a single sequential agent wherever two units
// would otherwise write the same files. Delete this block if the plan has no
// independent work; a parallel() over dependent phases corrupts the tree.
// Every parallel() needs its own FANOUT batch and a gate as the statement
// before it (batch "fanout" below, added to FANOUT.batches):
//
// const fan = await gate("before fan-out", "fanout")
// if (!fan || !fan.ok) return { plan: PLAN_PATH, stopped: "resource-floor", gate: fan, phases: results }
// const reviews = await parallel(
//   INDEPENDENT_UNITS.map((unit) => () => agent(preamble(unit.title) + unit.instruction,
//     { model: {{model-js:worker}}, phase: "PHASE ONE TITLE", label: unit.title, schema: PHASE_SCHEMA }))
// )

if (stoppedBy) {
  return { plan: PLAN_PATH, stopped: "resource-floor", gate: stoppedBy, phases: results }
}

const landed = results.filter((r) => r.landed)
// The plan-wide acceptance suite only means something once every phase has
// landed. A check-in run (a non-empty `only`) or a run that stopped on a failed
// phase skips it instead of reporting a premature failure. Pass {verify: true}
// to run it anyway, for example alongside the last check-in phase.
const fullRun = only.length === 0 && landed.length === PHASES.length
let verification = null
if (fullRun || input.verify === true) {
  phase("Verify")
  verification = await agent(
    "Every phase below reports having landed and self-verified. Independently confirm the " +
    "plan's own acceptance criteria in " + REPO_PATH + ": run the plan's full check suite " +
    "yourself and read the real output. Report green only on evidence.\n\n" +
    "Phase results:\n" + JSON.stringify(results, null, 2),
    { model: {{model-js:critic}}, phase: "Verify", schema: PHASE_SCHEMA }
  )
} else {
  log("Skipping Verify: partial run (" + landed.length + " of " + PHASES.length + " phases landed)")
}

return {
  plan: PLAN_PATH,
  phases: results,
  landedCount: landed.length,
  totalPhases: PHASES.length,
  complete: landed.length === PHASES.length,
  verification
}
