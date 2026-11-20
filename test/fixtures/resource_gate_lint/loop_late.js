export const meta = {
  name: "fixture",
  description: "fixture",
  phases: [ { title: "Resource floors" }, { title: "Build" } ]
}
const FANOUT = { worktrees: 1, batches: { phase: [{ op: "rake_test", count: 1 }] } }
async function gate(where, batchName) {
  return await agent("gate " + where, { phase: "Resource floors" })
}
const PHASES = [ { title: "Build", instruction: "build" } ]
const results = []
phase("Resource floors")
const first = await gate("Phase 0", "phase")
for (const spec of PHASES) {
  phase(spec.title)
  const out = await agent(spec.instruction, { phase: spec.title })
  const g = await gate("after " + spec.title, "phase")
  results.push(out, g)
}
return { results }
