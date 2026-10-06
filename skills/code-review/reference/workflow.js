// cf:code-review Workflow script. Pass this file's contents verbatim as
// Workflow's `script` argument; do not paraphrase, summarize, or edit it in
// transit. It owns everything the old per-step Agent instructions used to
// describe by hand: sharding, model tiers, background/parallel dispatch, the
// P1 double-check, and the dedupe/rank/cap that turns raw candidates into
// `posted`. Comment text and the actual PR post stay outside it (SKILL.md's
// steps 3 and 4), since posting is a GitHub call this script has no tool to
// make.
//
// For maintainers: this script's own logic is documented inline below. For
// the Workflow tool's general API (agent/pipeline/parallel/phase/schema
// semantics), see https://code.claude.com/docs/en/workflows.md and the full
// signature reference at https://code.claude.com/docs/en/agent-sdk/typescript.
// This script runs in a sandboxed context with no tool access, so nothing
// here can fetch those docs at runtime; they are for a human keeping this
// script in sync with the tool's actual API.
//
// Model tiers: the script picks a model per call so the cheap tier is used
// only where the work is itself high-volume and mechanically separable,
// never as a reflex.
//   Shard mapping             opus    One call gates the whole run; needs
//                                     real semantic boundaries, not directory
//                                     splits.
//   Find, folded (small shard) inherit One pass covering both lenses; no
//                                     checklist-only slice big enough to
//                                     split out.
//   Find, rubric split (large) haiku  Applies an already-written skill's
//                                     rules across enough files to be its
//                                     own job.
//   Find, general split (large) inherit No checklist; needs full reasoning
//                                     to name what a rubric cannot.
//   Verify                     inherit Must write and run a real repro or
//                                     refactor correctly.
//   Recheck P1                 opus   Low volume, highest stakes: gates a
//                                     red, auto-apply-diff finding.

export const meta = {
  name: "cf-code-review-scope",
  description: "Shard, find, worktree-verify, and rank code review findings for one scope",
  phases: [
    { title: "Shard" },
    { title: "Find" },
    { title: "Verify" },
    { title: "Recheck P1", model: "opus" }
  ]
}

const SHARD_SCHEMA = {
  type: "object",
  properties: {
    shards: {
      type: "array",
      items: {
        type: "object",
        properties: {
          name: { type: "string" },
          rationale: { type: "string" },
          files: { type: "array", items: { type: "string" } }
        },
        required: [ "name", "files" ]
      }
    }
  },
  required: [ "shards" ]
}

const CANDIDATES_SCHEMA = {
  type: "object",
  properties: {
    candidates: {
      type: "array",
      items: {
        type: "object",
        properties: {
          file: { type: "string" },
          line: { type: "number" },
          scenario: { type: "string" },
          source: { type: "string" }
        },
        required: [ "file", "line", "scenario" ]
      }
    }
  },
  required: [ "candidates" ]
}

const VERDICT_SCHEMA = {
  type: "object",
  properties: {
    reproduced: { type: "boolean" },
    evidence: { type: "string" },
    tier: { type: "string", enum: [ "P1", "P2", "P3" ] },
    title: { type: "string" },
    suggestion: { type: "string" }
  },
  required: [ "reproduced", "evidence", "tier", "title" ]
}

const RECHECK_SCHEMA = {
  type: "object",
  properties: {
    reproduced: { type: "boolean" },
    evidence: { type: "string" }
  },
  required: [ "reproduced", "evidence" ]
}

// Some hosts hand this script a JSON-encoded string instead of the parsed
// object the Workflow contract promises; tolerate both.
const scope = typeof args === "string" ? JSON.parse(args) : args

const files = scope.files
const repoPath = scope.repoPath
const headSha = scope.headSha
const shardThreshold = scope.shardThreshold ?? 40
const rubricThreshold = scope.rubricThreshold ?? 25
const cap = scope.cap ?? 15

// isolation: "worktree" on the Agent calls below only isolates this
// session's own primary repo, not repoPath, so it is not used here.
// Verify and Recheck P1 manage their own git worktree of repoPath instead,
// which is correct whether repoPath is the primary repo or a separate one.
function locKey(finding) {
  return finding.file + ":" + finding.line
}

function worktreeSetup() {
  return "Before doing anything else, create a throwaway checkout: run " +
    "`d=$(mktemp -d) && git -C " + repoPath + " worktree add \"$d\" " + headSha +
    " && echo \"$d\"`, then do every reproduction step inside that echoed path, " +
    "never in " + repoPath + " itself. Remove it when done with `git -C " + repoPath +
    " worktree remove \"<path>\" --force`. "
}

phase("Shard")
let shards
if (files.length <= shardThreshold) {
  shards = [ { name: "scope", files: files, rationale: "small enough for one pass" } ]
} else {
  const map = await agent(
    "Map this file list into coherent semantic sections a reviewer would treat as one unit " +
    "(e.g. auth, billing, the caching layer), not directory splits. Give each section a short " +
    "name, a one-line rationale, and its file list.\n\nFiles:\n" + files.join("\n"),
    { model: "opus", phase: "Shard", schema: SHARD_SCHEMA }
  )
  // Row 34: a null Shard result must not throw. One shard holding every
  // file is always a safe, if coarse, fallback.
  shards = (map && map.shards) ? map.shards : [ { name: "scope", files: files, rationale: "shard agent returned null or incomplete" } ]
}
// Row 36: a non-null map that drops files from every shard must not lose
// those files from review. Leftover files become their own shard.
const shardedFiles = new Set(shards.flatMap((s) => s.files))
const leftover = files.filter((f) => !shardedFiles.has(f))
if (leftover.length > 0) {
  shards = shards.concat([ { name: "leftover", files: leftover, rationale: "omitted by the shard map" } ])
}
log(shards.length + " shard(s): " + shards.map((s) => s.name + " (" + s.files.length + ")").join(", "))

const shardResults = await pipeline(
  shards,
  async (shard) => {
    if (shard.files.length <= rubricThreshold) {
      const found = await agent(
        "Review these files for correctness bugs, security issues, missing or wrong test " +
        "coverage, and refactor opportunities. Apply the matched skill rubrics from " +
        "`ruby ~/.claude/cf/bin/skill_route.rb <files>` where they cover a file, plus general " +
        "judgment where they do not. Every candidate needs a concrete failure scenario, not a " +
        "vague quality note.\n\nFiles:\n" + shard.files.join("\n"),
        { phase: "Find", label: shard.name, schema: CANDIDATES_SCHEMA }
      )
      // Row 34/35: a null Find result must not throw, and must never pass
      // for a complete review of this shard.
      if (!found || !found.candidates) {
        return { shard: shard, candidates: [], incomplete: true }
      }
      return { shard: shard, candidates: found.candidates, incomplete: false }
    }
    const lensResults = await parallel([
      () => agent(
        "Route these files with `ruby ~/.claude/cf/bin/skill_route.rb <files>` and apply " +
        "each matched skill principles verbatim. Files:\n" + shard.files.join("\n"),
        { model: "haiku", phase: "Find", label: shard.name + ":rubric", schema: CANDIDATES_SCHEMA }
      ),
      () => agent(
        "General review pass, unscoped to any named rubric: correctness bugs, security, " +
        "API and contract breaks, missing or wrong test coverage, performance. Files:\n" +
        shard.files.join("\n"),
        { phase: "Find", label: shard.name + ":general", schema: CANDIDATES_SCHEMA }
      )
    ])
    // Row 35: one lens coming back null, or with no `candidates`, must mark
    // the shard incomplete instead of silently reviewing it with just the
    // surviving lens.
    const incomplete = lensResults.some((r) => !r || !r.candidates)
    const candidates = lensResults.filter((r) => r && r.candidates).flatMap((r) => r.candidates)
    return { shard: shard, candidates: candidates, incomplete: incomplete }
  },
  async (found) => {
    const seenKeys = new Set()
    const uniqueCandidates = found.candidates.filter((c) => {
      const key = locKey(c)
      if (seenKeys.has(key)) return false
      seenKeys.add(key)
      return true
    })
    const verified = await parallel(uniqueCandidates.map((c) => () =>
      agent(
        worktreeSetup() +
        "Try to refute this finding by reproducing it against the real code: " + locKey(c) +
        " - " + c.scenario + ". Reproduce with a failing test, an actual invocation, " +
        "or by applying a refactor and confirming behavior holds; do not just re-read the code " +
        "and agree. If it survives, also write a title: an imperative one-line headline under " +
        "60 characters naming what is wrong (e.g. 'Missing cf:ctx row in Command skills table'). " +
        "The title states what is wrong; it must not restate the scenario's detail or repeat its " +
        "wording, since both are posted together under one character budget.",
        { phase: "Verify", label: locKey(c), schema: VERDICT_SCHEMA }
      ).then((v) => (v ? { ...c, ...v } : null))
    ))
    const survivors = verified.filter(Boolean).filter((f) => f.reproduced)
    // A null Verify result is an unchecked candidate, not a refuted one: the
    // shard must not claim full coverage when any verdict is missing.
    const verifyMissing = verified.some((v) => !v)
    return { shard: found.shard, findings: survivors, incomplete: found.incomplete || verifyMissing }
  },
  async (verified) => {
    const p1s = verified.findings.filter((f) => f.tier === "P1")
    const rechecks = await parallel(p1s.map((f) => () =>
      agent(
        worktreeSetup() +
        "Independently try to reproduce this finding with no prior context: " + locKey(f) +
        " - " + f.scenario,
        { model: "opus", phase: "Recheck P1", label: locKey(f), schema: RECHECK_SCHEMA }
      ).then((r) => ({ key: locKey(f), confirmed: Boolean(r && r.reproduced) }))
    ))
    const confirmedKeys = new Set(rechecks.filter((r) => r.confirmed).map((r) => r.key))
    const findings = verified.findings.map((f) => {
      if (f.tier !== "P1") return f
      const key = locKey(f)
      return confirmedKeys.has(key) ? f : { ...f, tier: "P2", suggestion: undefined }
    })
    return { shard: verified.shard, findings: findings, incomplete: verified.incomplete }
  }
)

const all = shardResults.filter(Boolean).flatMap((r) => r.findings)
const byKey = new Map()
for (const f of all) {
  const key = locKey(f)
  if (!byKey.has(key)) byKey.set(key, f)
}
const rank = { P1: 0, P2: 1, P3: 2 }
const eligible = [ ...byKey.values() ].filter((f) => f.tier !== "P3" || f.suggestion)
const ranked = eligible.sort((a, b) => rank[a.tier] - rank[b.tier])

// Row 35: the result always states whether every shard was fully covered,
// so a caller never posts findings while silently claiming completeness.
const incompleteShards = shardResults.filter(Boolean).filter((r) => r.incomplete).map((r) => r.shard.name)

return {
  shards: shards.map((s) => ({ name: s.name, files: s.files.length })),
  posted: ranked.slice(0, cap),
  droppedForVolume: Math.max(0, ranked.length - cap),
  incomplete: incompleteShards.length > 0,
  incompleteShards: incompleteShards
}
