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
if (!first || !first.ok) {
  return { stopped: "resource-floor", gate: first }
}
for (const spec of PHASES) {
  phase(spec.title)
  const g = await gate("start of " + spec.title, "phase")
  if (!g || !g.ok) {
    break
  }
  const out = await agent(spec.instruction, { phase: spec.title })
  results.push(out)
}
const fan = await gate("before fan-out", "phase")
if (!fan || !fan.ok) return { stopped: "resource-floor", gate: fan }
const reviews = await parallel(PHASES.map((p) => () => agent(p.title, { phase: "Build" })))
return { results, reviews }
