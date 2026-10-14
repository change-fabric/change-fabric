#!/usr/bin/env node
// Model harness for the QA coverage page. Pulls the inline
// <script id="cf-coverage-model"> out of a rendered index.html, runs it in a
// node:vm context with a bare fake `window` (no DOM, which is the point: the
// model must be pure), and evaluates test expressions against it, so
// test/change_coverage_page_test.rb can assert the page's numbers without a
// browser.
//
// Usage:
//   node coverage_page_harness.mjs <index.html> < fixture.json
//
// stdin is { "data": <window.CF_QA_COVERAGE value>, "exprs": { "<name>": "<js>" } }.
// Each expression sees `M` (window.CFCoverageModel), `data`, and `N`
// (M.normalize(data)). Prints one JSON object { "<name>": <value>, ... }; an
// expression that throws yields { "error": "<message>" } under its name.

import fs from "node:fs"
import path from "node:path"
import vm from "node:vm"

const htmlPath = process.argv[2]
if (!htmlPath) {
  console.error("usage: coverage_page_harness.mjs <index.html> < fixture.json")
  process.exit(2)
}

const html = fs.readFileSync(path.resolve(htmlPath), "utf8")
const match = html.match(/<script id="cf-coverage-model">([\s\S]*?)<\/script>/)
if (!match) {
  console.error("cf-coverage-model script not found")
  process.exit(2)
}

const input = JSON.parse(fs.readFileSync(0, "utf8"))
const context = vm.createContext({ window: {} })
vm.runInContext(match[1], context, { filename: "cf-coverage-model" })
context.data = input.data
vm.runInContext("var M = window.CFCoverageModel; var N = M.normalize(data);", context)

const out = {}
for (const [name, expr] of Object.entries(input.exprs || {})) {
  try {
    // Round-trip through JSON inside the context so values cross realms as
    // plain data.
    out[name] = JSON.parse(vm.runInContext(`JSON.stringify((${expr}) === undefined ? null : (${expr}))`, context))
  } catch (e) {
    out[name] = { error: String(e && e.message ? e.message : e) }
  }
}
process.stdout.write(JSON.stringify(out) + "\n")
