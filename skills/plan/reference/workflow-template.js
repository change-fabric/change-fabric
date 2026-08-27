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
//
// Model tiers: pick per call, and only where the work justifies it. `haiku`
// for high-volume mechanically bounded classification. `opus` for the low
// volume, high stakes calls that gate everything downstream. Omit `model` to
// inherit, which is the right default for an agent that reads real output.

export const meta = {
  name: "PLAN-SLUG",
  description: "ONE LINE, WHAT THIS BUILD DOES, TAKEN FROM goal.md",
  phases: [
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

const input = typeof args === "string" ? JSON.parse(args) : (args ?? {})
const stopOnFailure = input.stopOnFailure ?? true

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
for (const spec of PHASES) {
  phase(spec.title)
  const result = await agent(
    preamble(spec.title) + spec.instruction +
    "\n\nWhen the work is done, run this and report its real output, do not assume it:\n" +
    spec.verify +
    "\n\nSet landed: false if the verification did not pass. Do not report a phase " +
    "landed on the strength of the code looking right.",
    { phase: spec.title, schema: PHASE_SCHEMA }
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
//
// const reviews = await parallel(
//   INDEPENDENT_UNITS.map((unit) => () => agent(preamble(unit.title) + unit.instruction,
//     { phase: "PHASE ONE TITLE", label: unit.title, schema: PHASE_SCHEMA }))
// )

phase("Verify")
const landed = results.filter((r) => r.landed)
const verification = await agent(
  "Every phase below reports having landed and self-verified. Independently confirm the " +
  "plan's own acceptance criteria in " + REPO_PATH + ": run the plan's full check suite " +
  "yourself and read the real output. Report green only on evidence.\n\n" +
  "Phase results:\n" + JSON.stringify(results, null, 2),
  { model: "opus", phase: "Verify", schema: PHASE_SCHEMA }
)

return {
  plan: PLAN_PATH,
  phases: results,
  landedCount: landed.length,
  totalPhases: PHASES.length,
  complete: landed.length === PHASES.length,
  verification
}
