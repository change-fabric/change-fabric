#!/usr/bin/env node
// Null-injection harness for a skill's reference/workflow.js. Runs the
// workflow source as a real AsyncFunction with agent/parallel/pipeline/
// phase/log stubbed out, so test/workflow_null_harness_test.rb can assert
// what each workflow does when one agent() call returns null or a result
// missing a field, without a real sub-agent or network access.
//
// Usage:
//   node workflow_harness.mjs <workflow.js> --fixture <fixture.json> \
//     [--null <call-site-key>] [--partial <call-site-key> --partial-field <name>]
//
// The fixture is { "args": <workflow's input>, "results": { "<key>": <happy
// agent() result>, ... } }. A call-site key is `${label ?? phase}#${n}`,
// where n counts occurrences of that base across the whole run in call
// order, so two calls that share a label (or share no label and fall back
// to the phase name) get distinct keys automatically.
//
// Prints one JSON line: { result, calls } on a normal return, or
// { threw: "<message>", calls } if the workflow source throws. `calls` is
// the ordered list of call-site keys actually invoked, so a caller can
// enumerate every key from a happy run without hardcoding them.

import fs from "node:fs"
import path from "node:path"

function parseArgs(argv) {
  const out = { _: [] }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === "--fixture") out.fixture = argv[++i]
    else if (a === "--null") out.null = argv[++i]
    else if (a === "--partial") out.partial = argv[++i]
    else if (a === "--partial-field") out.partialField = argv[++i]
    else out._.push(a)
  }
  return out
}

const argv = parseArgs(process.argv.slice(2))
const workflowPath = argv._[0]

if (!workflowPath || !argv.fixture) {
  console.error("usage: workflow_harness.mjs <workflow.js> --fixture <fixture.json> [--null <key>] [--partial <key> --partial-field <name>]")
  process.exit(2)
}

const src = fs.readFileSync(path.resolve(workflowPath), "utf8").replace(/^export /m, "")
const fixture = JSON.parse(fs.readFileSync(path.resolve(argv.fixture), "utf8"))
const fixtureResults = fixture.results || {}
const workflowArgs = fixture.args

const counts = new Map()
function nextKey(base) {
  const n = (counts.get(base) || 0) + 1
  counts.set(base, n)
  return base + "#" + n
}

const calls = []

async function agent(prompt, opts = {}) {
  const base = String(opts.label ?? opts.phase ?? "unlabeled")
  const key = nextKey(base)
  calls.push(key)

  if (argv.null === key) return null

  if (!(key in fixtureResults)) {
    throw new Error("no fixture result for call-site key " + JSON.stringify(key))
  }
  const value = JSON.parse(JSON.stringify(fixtureResults[key]))

  if (argv.partial === key && argv.partialField) {
    delete value[argv.partialField]
  }

  return value
}

function parallel(fns) {
  return Promise.all(fns.map((fn) => fn()))
}

// Mirrors the Workflow tool's pipeline: each item runs through every stage
// in order, independently of the other items.
function pipeline(items, ...stages) {
  return Promise.all(items.map(async (item) => {
    let value = item
    for (const stage of stages) value = await stage(value)
    return value
  }))
}

const phases = []
function phase(name) { phases.push(name) }
function log() {}

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
const fn = new AsyncFunction("args", "agent", "parallel", "pipeline", "phase", "log", src)

try {
  const result = await fn(workflowArgs, agent, parallel, pipeline, phase, log)
  console.log(JSON.stringify({ result, calls, phases }))
} catch (e) {
  console.log(JSON.stringify({ threw: String((e && e.message) || e), calls, phases }))
}
