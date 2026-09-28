// Template for the `workflow.js` that cf:drive thorough lands beside plan.md and
// goal.md. It has two halves, split by the two marker lines below:
//
//  - PLAN: filled per run by the writing agent. Every string that starts with
//    FILL and a colon is a placeholder; a landed workflow.js with one left in
//    it has not been written. Delete optional entries the plan does not need rather than leaving
//    them as placeholders.
//  - ENGINE: identical in every thorough plan. It carries the guards a real
//    release run had to patch in by hand, so a plan cannot silently drop one.
//    SKILL.md step 8 diffs this half against the template and fails the plan on
//    any difference. The executing session may still patch it when reality
//    demands; it records each patch and why in run-log.md.
//
// Workflow authoring contract (see skills/plan/reference/workflow-template.js
// for the long form): `meta` is a literal read before the script runs; the
// script body has no tool access, so every real action happens inside
// agent(); no wall-clock reads and no randomness, because the prelude re-runs
// on resume; `args` is the only input.
//
// One segment runs per call, chosen by args.segment, because the run is broken
// up by human gates no agent may pass (owner rulings, merges, database and prod
// steps). Each segment returns `nextStep` and `ownerQuestions`, and the
// executing session stops there. plan.md, section "Workflow segments", lists
// each segment's args for this run.

export const meta = {
  name: "FILL: thorough-SLUG",
  description: "FILL: ONE LINE FROM goal.md, WHAT SHIPS AND THE SHIP OR NO-SHIP CALL IT ENDS IN",
  phases: [
    { title: "Scope" },
    { title: "Review" },
    { title: "Fix" },
    { title: "Gate" },
    { title: "QA" },
    { title: "Audit" },
    { title: "Handoff" },
    { title: "Main thread" }
  ]
}

// ===== PLAN: filled per run by the writing agent =====

// Paths use '~' for the home directory, never a literal home path. Lists, not
// totals: any count the engine or an agent needs is derived from its list, so a
// stated total can never disagree with its own itemization.
const PLAN = {
  slug: "FILL: plan slug",
  // "pr-high" (one PR touching money, auth, PII or schema) or "release" (a
  // range such as development -> production). A low-risk PR never gets here;
  // cf:drive thorough recommends `/cf:drive quick` instead.
  tier: "FILL: pr-high or release",
  repoPath: "FILL: ~/path/to/primary/clone",
  planDir: "FILL: ~/.claude/cf/plans/AREA/SLUG",
  worktreeRoot: "FILL: ~/path/to/worktrees",
  // Private scratch for dumps and QA env files: mode 700, never inside planDir.
  privateDir: "FILL: ~/path/to/worktrees/SLUG-private",
  envFile: "FILL: ~/path/to/primary/clone/.env.local",
  envLinkDirs: [ "FILL: repo-relative dirs a fresh worktree symlinks envFile into; '.' for the root" ],
  installCommand: "FILL: e.g. pnpm install --frozen-lockfile",
  // Range ends as remote refs. `head` is the ref whose tip every segment
  // checks against args.expectedTip.
  base: "FILL: e.g. origin/production",
  head: "FILL: e.g. origin/development",
  prNumber: 0,
  // Paths the diff touches per risk area, from the scope agent. Drives the
  // unit coverage check below and the handoff's diffs-to-read.
  riskAreas: {
    money: [ "FILL: repo-relative paths or globs, or delete the key" ],
    auth: [],
    pii: [],
    schema: []
  },
  severity: {
    levels: [
      { name: "blocker", means: "wrong money, data loss, auth bypass, PII leak, broken core flow, prod-day failure" },
      { name: "should-fix", means: "a real bug a user will hit, an a11y failure on a core flow, a missing guard with a plausible path" },
      { name: "nit", means: "style, polish, speculative" }
    ],
    blocking: [ "blocker", "should-fix" ]
  },
  review: {
    exclusions: [ "FILL: path or commit class excluded, with the evidence for excluding it" ],
    knownDeferred: [ "FILL: an issue reviewers must not report again" ],
    // kind: review, money, security or schema. One read-only reviewer per unit.
    units: [
      {
        id: "RU1",
        kind: "FILL: review|money|security|schema",
        title: "FILL: unit title",
        scope: [ "FILL: git diff BASE HEAD -- paths (local ranges only)" ],
        focus: "FILL: what this reviewer hunts for"
      }
    ]
  },
  fix: {
    // "fix-prs": one PR per batch against baseBranch (release tier).
    // "pr-branch": commits on the PR's own branch (pr-high tier).
    mode: "FILL: fix-prs or pr-branch",
    baseBranch: "FILL: branch fix PRs target, or the PR's base",
    prBranch: "FILL: the PR's head branch (pr-branch mode), else delete",
    branchPrefix: "FILL: e.g. fix/SLUG-",
    schemaPaths: [ "FILL: paths a fix agent must never touch (migrations, schema)" ],
    forbiddenPaths: [],
    preMergeVerify: true,
    mergeAuthorizer: "FILL: who authorizes each merge, in chat",
    mergeCommand: "FILL: e.g. gh pr merge <n> --squash --admin"
  },
  gate: {
    // Run in this order, each as its own command.
    chain: [ "FILL: e.g. pnpm build" ],
    notes: [ "FILL: ordering constraints, pre-existing failures tolerated, coverage floor" ],
    // The recorded cf:change run the merge guard reads. Empty when the repo has
    // no CHANGE.md or the target branch is not protected.
    change: "FILL: ruby ~/.claude/cf/bin/change_run.rb all ... or empty string"
  },
  // kind: "test" or "build". A listed flake gets one retry.
  flakes: [ { match: "FILL: test file or error text", kind: "test" } ],
  // Hosts, people and billable services no agent may reach, by name.
  neverContact: [ "FILL: production host", "FILL: real people's email and phone", "FILL: billable service" ],
  qa: {
    // Where write-QA runs: "prodcopy", "seeded" or "staging".
    target: "FILL: prodcopy|seeded|staging",
    server: "FILL: URL and the command that (re)launches it in the background",
    signIn: "FILL: how an agent signs in on the local target",
    browser: "FILL: driver, viewports (desktop and 390), themes",
    mailbox: "FILL: captured-mail API URL, or delete",
    // Setup lane: runs first, alone; a failure ends all QA.
    setup: [ "FILL: restore, migrate, data scripts, count comparison, mail capture, SMS off, billable keys blanked" ],
    safetyProbe: "FILL: the check that mail lands in capture and nothing leaves",
    // Throwaway seeded environment for pre-merge QA of open fixes.
    throwaway: [ "FILL: containers, env, seed commands" ],
    throwawayCleanup: [ "FILL: teardown commands" ],
    lanes: [
      {
        id: "FILL: lane id",
        title: "FILL: lane title",
        target: "FILL: prodcopy|seeded|staging",
        roles: [ "FILL: role" ],
        flows: [ "FILL: flow with its concrete assertion" ],
        // Exact commands with every target flag written out. Agents run them
        // as written and never drop a flag.
        commands: []
      }
    ]
  },
  handoff: {
    // Paths the owner reads before merge regardless of fixes.
    mustRead: [ "FILL: repo-relative paths" ],
    finalPass: [ "FILL: owner final-pass checklist item, with a time box" ],
    // Plan.md sections copied verbatim into owner-handoff.md; empty when no
    // deploy is in scope.
    verbatimSections: [ "FILL: e.g. Prod-day checklist", "FILL: e.g. Rollback" ]
  },
  // Steps only the main thread may do. Each returns its pointer; no agent runs.
  mainThread: [
    { id: "FILL: e.g. merge", title: "FILL: title", pointer: "FILL: what the main thread does, citing plan.md" }
  ],
  // Extra project hard rules appended to every agent's rules.
  rules: []
}

// ===== ENGINE: identical in every thorough plan; do not edit at planning time =====

const input = typeof args === "string" ? JSON.parse(args) : (args ?? {})
const segment = input.segment ?? ""
const mode = input.mode ?? ""
const expectedTip = input.expectedTip ?? ""
// Unknown merge mode means the safest one: commit locally, push nothing.
const mergeMode = input.mergeMode ?? "local-only"
const listOf = (value) => (Array.isArray(value) ? value : [])

const FILES = {
  review: PLAN.planDir + "/review-findings.md",
  qa: PLAN.planDir + "/qa-report.md",
  gate: PLAN.planDir + "/gate-log.md",
  followups: PLAN.planDir + "/followups.md",
  handoff: PLAN.planDir + "/owner-handoff.md",
  runLog: PLAN.planDir + "/run-log.md"
}
const PLAN_MD = PLAN.planDir + "/plan.md"
const SAFETY_PREFIX = "SAFETY STOP: "
const FIX_MODE = PLAN.fix.mode
const FULL_DIFF_ROUNDS = 2
const UNIT_KIND_FOR_AREA = { money: "money", auth: "security", pii: "security", schema: "schema" }

// ---------------------------------------------------------------- plan checks
// Deterministic, before any agent runs. A plan that fails here returns its
// problems and runs nothing.

function flagValue(command, flag) {
  const match = command.match(new RegExp(flag + "[ =](\\S+)"))
  return match ? match[1] : null
}

// A sweep aimed at a named target must name its health URL under that same
// target: the profile default can point at production, and omitting the flag
// once sent health checks there.
function sweepProblems(label, command, isLane) {
  if (!/change_run\.rb/.test(command)) return []
  const target = flagValue(command, "--target-url")
  const health = flagValue(command, "--health-url")
  const problems = []
  if (/--profile\b/.test(command) || target) {
    if (!target) problems.push(label + ": change_run.rb with --profile but no --target-url")
    if (!health) problems.push(label + ": change_run.rb without --health-url")
    if (target && health && !health.startsWith(target)) {
      problems.push(label + ": --health-url " + health + " is not under --target-url " + target)
    }
  }
  if (isLane && !/--no-publish\b/.test(command)) problems.push(label + ": QA sweep without --no-publish")
  return problems
}

function planProblems() {
  const problems = []
  if (![ "pr-high", "release" ].includes(PLAN.tier)) problems.push("tier must be pr-high or release")
  if (![ "fix-prs", "pr-branch" ].includes(FIX_MODE)) problems.push("fix.mode must be fix-prs or pr-branch")
  if (listOf(PLAN.review.units).length === 0) problems.push("review.units is empty")
  for (const [ area, paths ] of Object.entries(PLAN.riskAreas ?? {})) {
    const kind = UNIT_KIND_FOR_AREA[area]
    if (listOf(paths).length > 0 && kind && !PLAN.review.units.some((u) => u.kind === kind)) {
      problems.push("the diff touches " + area + " but no review unit has kind " + kind)
    }
  }
  const laneIds = listOf(PLAN.qa.lanes).map((l) => l.id)
  if (laneIds.includes("setup")) problems.push("lane id 'setup' is reserved for the engine's setup lane")
  if (new Set(laneIds).size !== laneIds.length) problems.push("duplicate lane ids")
  for (const lane of listOf(PLAN.qa.lanes)) {
    listOf(lane.commands).forEach((c, i) => problems.push(...sweepProblems("lane " + lane.id + " command " + (i + 1), c, true)))
  }
  if (PLAN.gate.change) problems.push(...sweepProblems("gate.change", PLAN.gate.change, false))
  return problems
}

// ---------------------------------------------------------------- schemas

const OWNER_QUESTIONS = { type: "array", items: { type: "string" } }

const SCOPE_SCHEMA = {
  type: "object",
  properties: {
    tip: { type: "string" },
    baseTip: { type: "string" },
    changedFiles: { type: "array", items: { type: "string" } },
    uncoveredFiles: { type: "array", items: { type: "string" } },
    riskAreasTouched: { type: "array", items: { type: "string" } },
    stopReasons: { type: "array", items: { type: "string" } },
    ownerQuestions: OWNER_QUESTIONS
  },
  required: [ "tip", "changedFiles", "uncoveredFiles", "stopReasons" ]
}

const FINDING_ITEM = {
  type: "object",
  properties: {
    title: { type: "string" },
    severity: { type: "string" },
    file: { type: "string" },
    line: { type: "number" },
    scenario: { type: "string" },
    suggestion: { type: "string" },
    confidence: { type: "string", enum: [ "high", "medium", "low" ] }
  },
  required: [ "title", "severity", "file", "scenario", "suggestion", "confidence" ]
}

const REVIEW_SCHEMA = {
  type: "object",
  properties: {
    unit: { type: "string" },
    tipReviewed: { type: "string" },
    rangeCommands: { type: "array", items: { type: "string" } },
    findings: { type: "array", items: FINDING_ITEM },
    verdicts: { type: "array", items: { type: "string" } },
    coverageNotes: { type: "string" }
  },
  required: [ "unit", "tipReviewed", "findings" ]
}

const LEDGER_SCHEMA = {
  type: "object",
  properties: {
    written: { type: "array", items: { type: "string" } },
    openBlockingIds: { type: "array", items: { type: "string" } },
    counts: { type: "object" },
    newFlakes: { type: "array", items: { type: "string" } }
  },
  required: [ "written", "openBlockingIds" ]
}

const BATCH_SCHEMA = {
  type: "object",
  properties: {
    batches: {
      type: "array",
      items: {
        type: "object",
        properties: {
          slug: { type: "string" },
          branch: { type: "string" },
          findingIds: { type: "array", items: { type: "string" } },
          files: { type: "array", items: { type: "string" } },
          notes: { type: "string" }
        },
        required: [ "slug", "branch", "findingIds", "files", "notes" ]
      }
    },
    escalations: { type: "array", items: { type: "string" } }
  },
  required: [ "batches", "escalations" ]
}

const COMMAND_ROW = {
  type: "object",
  properties: {
    command: { type: "string" },
    result: { type: "string" },
    retried: { type: "boolean" },
    seconds: { type: "number" }
  },
  required: [ "command", "result" ]
}

const APPLY_SCHEMA = {
  type: "object",
  properties: {
    landed: { type: "boolean" },
    branch: { type: "string" },
    headSha: { type: "string" },
    prUrl: { type: "string" },
    fixedIds: { type: "array", items: { type: "string" } },
    unfixedIds: { type: "array", items: { type: "string" } },
    failingFirst: { type: "string" },
    gateRows: { type: "array", items: COMMAND_ROW },
    newFlakes: { type: "array", items: { type: "string" } },
    stopReasons: { type: "array", items: { type: "string" } },
    ownerQuestions: OWNER_QUESTIONS
  },
  required: [ "landed", "branch", "fixedIds", "failingFirst", "gateRows", "stopReasons" ]
}

const GATE_SCHEMA = {
  type: "object",
  properties: {
    tip: { type: "string" },
    green: { type: "boolean" },
    rows: { type: "array", items: COMMAND_ROW },
    changeRecorded: { type: "boolean" },
    newFlakes: { type: "array", items: { type: "string" } },
    stopReasons: { type: "array", items: { type: "string" } }
  },
  required: [ "tip", "green", "rows", "stopReasons" ]
}

const LANE_SCHEMA = {
  type: "object",
  properties: {
    lane: { type: "string" },
    tipTested: { type: "string" },
    passed: { type: "boolean" },
    flowsRun: { type: "array", items: { type: "string" } },
    blockedFlows: {
      type: "array",
      items: {
        type: "object",
        properties: {
          flow: { type: "string" },
          reason: { type: "string" },
          needsOwner: { type: "boolean" }
        },
        required: [ "flow", "reason", "needsOwner" ]
      }
    },
    findings: {
      type: "array",
      items: {
        type: "object",
        properties: {
          title: { type: "string" },
          severity: { type: "string" },
          flow: { type: "string" },
          role: { type: "string" },
          viewport: { type: "string" },
          theme: { type: "string" },
          repro: { type: "string" },
          expectedVsActual: { type: "string" },
          confidence: { type: "string" }
        },
        required: [ "title", "severity", "flow", "repro", "expectedVsActual" ]
      }
    },
    newFlakes: { type: "array", items: { type: "string" } },
    stopReasons: { type: "array", items: { type: "string" } }
  },
  required: [ "lane", "tipTested", "passed", "flowsRun", "blockedFlows", "findings", "stopReasons" ]
}

const AUDIT_SCHEMA = {
  type: "object",
  properties: {
    checkedIds: { type: "array", items: { type: "string" } },
    candidates: {
      type: "array",
      items: {
        type: "object",
        properties: {
          id: { type: "string" },
          from: { type: "string" },
          to: { type: "string" },
          why: { type: "string" }
        },
        required: [ "id", "from", "to", "why" ]
      }
    }
  },
  required: [ "checkedIds", "candidates" ]
}

const HANDOFF_SCHEMA = {
  type: "object",
  properties: {
    verdict: { type: "string", enum: [ "READY", "NOT READY" ] },
    reasons: { type: "array", items: { type: "string" } },
    diffCommands: { type: "array", items: { type: "string" } },
    written: { type: "boolean" }
  },
  required: [ "verdict", "reasons", "diffCommands", "written" ]
}

// ---------------------------------------------------------------- prompts

const SEVERITY_TEXT =
  "Severity, exactly one of: " +
  PLAN.severity.levels.map((l) => l.name + " (" + l.means + ")").join("; ") + ". " +
  "Who can trigger a bug never lowers its severity: an admin-only path to wrong money or a " +
  "misdirected email carrying PII is still that severity. Confidence is a separate field. Every " +
  "finding needs file and line, a concrete scenario, a suggested fix and a confidence. Report only " +
  "what you verified by reading the code or driving the app.\n\n"

const RULES =
  "Hard rules for this agent:\n" +
  "- Do not fork, spawn sub-agents or use helper agents. Parallel agents against one shared " +
  "database and Docker have crashed a run.\n" +
  "- Never merge or approve a pull request. The main thread merges after " + PLAN.fix.mergeAuthorizer +
  " authorizes in chat.\n" +
  "- Never contact any of these: " + PLAN.neverContact.join("; ") + ". Target URLs and flags come " +
  "only from the plan's commands; run them as written and never drop or change a flag.\n" +
  "- If a tool call is denied by a permission rule or the auto-mode classifier, do not retry it and " +
  "do not route around it. Record it (a blocked flow with needsOwner, or an ownerQuestions entry) " +
  "and continue with what remains.\n" +
  "- Work only in worktrees under " + PLAN.worktreeRoot + ", never in the primary clone at " +
  PLAN.repoPath + ". A fresh worktree gets " + PLAN.envFile + " symlinked into " +
  PLAN.envLinkDirs.join(", ") + ", then " + PLAN.installCommand + ".\n" +
  "- Session merge mode is " + mergeMode + ". Under local-only, commit but never push and never " +
  "open a PR.\n" +
  "- Authored text is plain ASCII: no em-dash, unicode bullet, ellipsis character or smart quotes. " +
  "No agent attribution on commits or PRs.\n" +
  "- Never write a connection string, OTP, password or other secret into any file under " +
  PLAN.planDir + ". Write no file there at all unless this prompt names you its writer.\n" +
  "- Give every commit and gate command a 600000 ms timeout.\n" +
  "- Flakes: if a failure matches one of these, retry once: " +
  PLAN.flakes.map((f) => f.match + " (" + f.kind + ")").join("; ") + ". Any other failure: rerun " +
  "once; if it then passes, report it in newFlakes and do not investigate it; if it fails again it " +
  "is a real failure.\n" +
  listOf(PLAN.rules).map((r) => "- " + r + "\n").join("")

function preamble(title) {
  return "You are executing one segment of a thorough plan that is already settled. Paths below " +
    "use '~' for the home directory; expand it before passing a path to a tool that needs a literal " +
    "absolute path. Read " + PLAN_MD + " first, in full, then do only the segment named below. Its " +
    "\"Decisions (settled, do not re-litigate)\" section records the owner's answers; treat them as " +
    "fixed.\n\nRepository: " + PLAN.repoPath + "\nSegment: " + title + "\n\n" + RULES + "\n"
}

function tipCheck() {
  const fetch = "First run 'git -C " + PLAN.repoPath + " fetch origin' and 'git -C " + PLAN.repoPath +
    " rev-parse " + PLAN.head + "'. "
  if (!expectedTip) return fetch + "Report that sha as the tip you worked on.\n\n"
  return fetch + "The expected tip is " + expectedTip + ". If it differs, do no further work: put " +
    "the actual sha in stopReasons and stop.\n\n"
}

// The single writer for review-findings.md, qa-report.md, gate-log.md and
// followups.md. Segment agents only return data; this agent is the only one
// that edits those files, so a count or a status cannot drift between writers.
function ledger(title, instruction, payload) {
  return agent(
    preamble(title) +
    "You are the single writer for " + FILES.review + ", " + FILES.qa + ", " + FILES.gate + " and " +
    FILES.followups + ". Each file already holds its template: keep its section order exactly. " +
    "Severity is a column, never a section. Statuses are open, fixing <ref>, fixed <ref>, wontfix " +
    "<owner-approved reason> or deferred <issue>; never overwrite fixing, fixed, wontfix or deferred " +
    "with open unless the instruction says a fix failed verification. Recompute every count in a " +
    "header from the rows, never by adding to the old number. Append each new flake to followups.md " +
    "as FLAKE-<n>. Do not edit code or any other file.\n\n" + instruction + "\n\n" +
    JSON.stringify(payload, null, 2),
    { phase: title, schema: LEDGER_SCHEMA }
  )
}

function reviewPrompt(unit) {
  const lens = unit.kind === "security"
    ? "You are a security engineer auditing part of this change: authentication, authorization, " +
      "data exposure and third-party PII egress."
    : unit.kind === "schema"
      ? "You are reviewing schema, migrations and data scripts: destructive or locking statements, " +
        "NOT NULL without defaults, unique indexes against existing duplicates, ordering against the runbook."
      : unit.kind === "money"
        ? "You are reviewing money paths: double submit, double post, rounding, refunds, balances, " +
          "and every refusal a money action should make."
        : "You are a senior engineer reviewing a colleague's change: correctness first, then " +
          "design, security and reuse."
  return preamble("Review") + tipCheck() + lens + " You are READ-ONLY: no edits, commits, pushes, " +
    "GitHub comments or writing worktrees. Use local git ranges only (git -C " + PLAN.repoPath +
    "); never gh pr diff, which fails on large PRs.\n\n" +
    "Unit " + unit.id + ": " + unit.title + "\nScope, run these then read surrounding code at " +
    PLAN.head + ":\n" + unit.scope.join("\n") + "\n\nFocus: " + unit.focus + "\n\n" +
    "Excluded: " + PLAN.review.exclusions.join("; ") + "\n\nKnown-deferred, do not report again: " +
    PLAN.review.knownDeferred.join("; ") + "\n\n" + SEVERITY_TEXT +
    "Return unit '" + unit.id + "', the tip, the range commands you ran, your findings, and " +
    "coverageNotes naming anything in scope you could not read."
}

function laneCommon() {
  return "QA conventions for every lane. Server: " + PLAN.qa.server + ". Check it before each flow " +
    "and relaunch it in the background when down. Sign-in: " + PLAN.qa.signIn + ". Browser: " +
    PLAN.qa.browser + ". Captured mail: " + (PLAN.qa.mailbox ?? "none") + ". Before your first flow, " +
    "run the safety probe, even when setup ran earlier: " + (PLAN.qa.safetyProbe ?? "confirm no " +
    "never-contact target is configured") + ". Screenshots and scripts " +
    "go in your scratchpad, never in " + PLAN.planDir + ". If a safety check fails (mail leaves " +
    "capture, a message reaches a real person, a never-contact host is reached), put a stop reason " +
    "starting exactly '" + SAFETY_PREFIX + "'. That prefix, and only that prefix, halts the remaining " +
    "lanes; never use it for anything else, and write other notes without it.\n\n" + SEVERITY_TEXT +
    "Report every flow with role, viewport and theme; every blocked flow with its reason and whether " +
    "the owner must decide it; every finding with repro and expected vs actual. Do not edit code.\n\n"
}

function laneSpec(lane) {
  return "Lane " + lane.id + ": " + lane.title + ". Target: " + lane.target + ". Roles: " +
    lane.roles.join(", ") + ".\nFlows:\n" + lane.flows.map((f, i) => (i + 1) + ". " + f).join("\n") +
    (listOf(lane.commands).length > 0
      ? "\nCommands, exactly as written:\n" + lane.commands.join("\n")
      : "") + "\n"
}

const SETUP_LANE = {
  id: "setup",
  prompt: () => "Lane setup, which every other lane depends on. Steps, in order:\n" +
    PLAN.qa.setup.map((s, i) => (i + 1) + ". " + s).join("\n") + "\nThen the safety probe: " +
    PLAN.qa.safetyProbe + "\nA failed step or probe goes in stopReasons, prefixed '" + SAFETY_PREFIX +
    "' when it is a safety failure; either ends all QA. Report counts you compared and any difference " +
    "as a finding.\n"
}

// ---------------------------------------------------------------- dispatch

const problems = planProblems()
if (problems.length > 0) {
  return { plan: PLAN_MD, ran: "nothing", error: "PLAN failed its checks", problems }
}

const MAIN_THREAD = Object.fromEntries(listOf(PLAN.mainThread).map((s) => [ s.id, s ]))
const SEGMENTS = [ "scope", "review", "fix", "gate", "qa", "audit", "handoff" ]
const usage = "args.segment is one of " + SEGMENTS.concat(Object.keys(MAIN_THREAD)).join(", ") +
  "; pass expectedTip and mergeMode with every segment."

if (MAIN_THREAD[segment]) {
  phase("Main thread")
  log(MAIN_THREAD[segment].title + " is a main-thread step; no agent runs.")
  return { plan: PLAN_MD, segment, ran: "no agents (main thread only)", nextStep: MAIN_THREAD[segment].pointer }
}

if (segment === "scope") {
  phase("Scope")
  const unitScopes = PLAN.review.units.map((u) => u.id + ": " + u.scope.join(" ; ")).join("\n")
  const scope = await agent(
    preamble("Scope") + tipCheck() +
    "Read-only. Record rev-parse of " + PLAN.base + " and " + PLAN.head + ". List changed files with " +
    "git diff --name-only " + PLAN.base + "..." + PLAN.head + ". Then list every changed file that no " +
    "review unit's scope covers and no exclusion explains (uncoveredFiles), and which risk areas " +
    "(money, auth, pii, schema) the changed files touch. Units:\n" + unitScopes + "\nExclusions: " +
    PLAN.review.exclusions.join("; ") + "\nWrite no files.",
    { phase: "Scope", schema: SCOPE_SCHEMA }
  )
  const gaps = scope ? scope.uncoveredFiles.length : null
  return {
    plan: PLAN_MD,
    segment,
    scope,
    ownerQuestions: scope ? listOf(scope.ownerQuestions) : [],
    nextStep: !scope || scope.stopReasons.length > 0
      ? "STOP: resolve scope.stopReasons with the owner."
      : gaps > 0
        ? "Main thread: record the tips in run-log.md, then ask the owner whether the " + gaps +
          " uncovered files join a unit or the exclusions; update PLAN before 'review'."
        : "Main thread: record the tips in run-log.md, then run segment 'review' with the same expectedTip."
  }
}

if (segment === "review") {
  phase("Review")
  const units = listOf(input.units).length > 0
    ? PLAN.review.units.filter((u) => input.units.includes(u.id))
    : PLAN.review.units
  const reviews = await parallel(units.map((unit) => () =>
    agent(reviewPrompt(unit), { phase: "Review", label: unit.id, schema: REVIEW_SCHEMA })))
  const results = units.map((unit, i) => ({ unit: unit.id, title: unit.title, result: reviews[i] ?? null }))
  const missing = results.filter((r) => !r.result).map((r) => r.unit)
  const written = await ledger("Review",
    "Merge these unit results into review-findings.md: one row per finding with ID <unit>-<k>, " +
    "severity, title, file:line, scenario, suggestion, confidence, status open. Merge duplicates " +
    "across units into one ID and name the other unit. Drop anything on the known-deferred list. " +
    "Fill the coverage section from each unit's coverageNotes and name any unit that returned " +
    "nothing. Copy every nit to followups.md.",
    results)
  return {
    plan: PLAN_MD,
    segment,
    units: results.map((r) => ({ unit: r.unit, findings: r.result ? r.result.findings.length : null })),
    missingUnits: missing,
    ledger: written,
    nextStep: missing.length > 0
      ? "Rerun segment 'review' with args.units = " + JSON.stringify(missing) + " before fixing."
      : "Run segment 'audit' in mode 'check' now if any finding looks under-rated, else segment 'fix' mode 'plan-batches'."
  }
}

if (segment === "fix" && mode === "plan-batches") {
  phase("Fix")
  const extraIds = listOf(input.extraIds)
  const batches = await agent(
    preamble("Fix") + tipCheck() +
    "Read-only. Read " + FILES.review + " and " + FILES.qa + ". Group every finding whose severity " +
    "is " + PLAN.severity.blocking.join(" or ") + " and whose status is open into as few batches as " +
    "practical. " +
    (FIX_MODE === "fix-prs"
      ? "Each batch becomes its own PR against " + PLAN.fix.baseBranch + ", so batches have disjoint " +
        "file sets and branch " + PLAN.fix.branchPrefix + "<slug>. "
      : "Batches are applied in order as commits on " + PLAN.fix.prBranch + "; branch is " +
        PLAN.fix.prBranch + " for every batch. ") +
    "Money, auth or schema-adjacent fixes never share a batch with cosmetic ones. " +
    (extraIds.length > 0 ? "Also include these, which the owner folded in: " + extraIds.join(", ") + ". " : "") +
    "Put in each batch's notes every constraint the fix agent must honor (owner rulings, callers " +
    "to keep working, tests that must stay green). A finding that needs a change under " +
    PLAN.fix.schemaPaths.join(", ") + " goes in escalations, not a batch.",
    { phase: "Fix", model: "opus", schema: BATCH_SCHEMA }
  )
  return {
    plan: PLAN_MD,
    segment,
    mode,
    batches,
    ownerQuestions: batches ? batches.escalations : [],
    nextStep: "Show the batches and escalations to the owner. Then run segment 'fix' mode 'apply' with " +
      "args.batches set to the approved batches (add revise: true to a batch that revises an open PR)."
  }
}

if (segment === "fix" && mode === "apply") {
  phase("Fix")
  const batches = listOf(input.batches)
  if (batches.length === 0) return { plan: PLAN_MD, segment, mode, error: "args.batches is empty" }
  const applied = []
  for (const batch of batches) {
    const worktree = PLAN.worktreeRoot + "/" + PLAN.slug + "-fix-" + (FIX_MODE === "fix-prs" ? batch.slug : "pr")
    const where = FIX_MODE === "fix-prs"
      ? (batch.revise
          ? "This batch revises an open PR: reuse worktree " + worktree + " on branch " + batch.branch +
            " (create the worktree from origin/" + batch.branch + " if missing), add commits on top, " +
            "push to the same branch, keep the same PR and update its body if the summary changed."
          : "Create worktree " + worktree + " on new branch " + batch.branch + " from origin/" +
            PLAN.fix.baseBranch + ". Open a PR against " + PLAN.fix.baseBranch + " with a title under " +
            "60 characters and a body of at most 640 characters listing the finding IDs and the gate result.")
      : "Use worktree " + worktree + " on branch " + PLAN.fix.prBranch + " (create it from origin/" +
        PLAN.fix.prBranch + " if missing, else pull it). Add commits on top and push to that branch."
    const result = await agent(
      preamble("Fix") + tipCheck() +
      "Fix batch '" + batch.slug + "'. Findings: " + listOf(batch.findingIds).join(", ") + " (rows in " +
      FILES.review + " and " + FILES.qa + "). Expected files: " + listOf(batch.files).join(", ") + ".\n" +
      "Planner notes, constraints to honor: " + (batch.notes ?? "none") + "\n" + where + "\n" +
      "For each finding, first write a test that fails, run it and keep its failing output for " +
      "failingFirst, then fix until it passes. Never touch " +
      PLAN.fix.schemaPaths.concat(listOf(PLAN.fix.forbiddenPaths)).join(", ") + "; if a finding needs " +
      "that, stop and put it in stopReasons. Then run each gate command in the worktree, in order, " +
      "and report each as a gate row:\n" + PLAN.gate.chain.join("\n") + "\nCommit, then push and open " +
      "or update the PR as above unless merge mode is local-only. Stop. Do not merge. Do not edit " +
      "any file under " + PLAN.planDir + ".\n\nSet landed: false if a gate command failed or a push " +
      "that merge mode allows did not happen.",
      { phase: "Fix", label: batch.slug, schema: APPLY_SCHEMA }
    )
    applied.push({ batch: batch.slug, findingIds: listOf(batch.findingIds), result: result ?? null })
  }
  const written = await ledger("Fix",
    "For each landed batch, set its fixed findings' status to 'fixing <prUrl or branch@headSha>'. " +
    "Leave unfixed findings open with a note. Append each batch's gate rows to gate-log.md as a " +
    "fix-branch gate for its branch and headSha.",
    applied)
  const landed = applied.filter((a) => a.result && a.result.landed)
  return {
    plan: PLAN_MD,
    segment,
    mode,
    applied: applied.map((a) => ({ batch: a.batch, landed: Boolean(a.result && a.result.landed), prUrl: a.result ? a.result.prUrl : null })),
    ledger: written,
    ownerQuestions: applied.flatMap((a) => (a.result ? listOf(a.result.ownerQuestions).concat(a.result.stopReasons) : [])),
    nextStep: landed.length === 0
      ? "STOP: no batch landed; read applied[].result.stopReasons."
      : "Run segment 'fix' mode 'verify' with args.open = [{ ref, branch, findingIds, round: 1 }] for " +
        "each landed batch" + (PLAN.fix.preMergeVerify ? ", before any merge." : ".")
  }
}

if (segment === "fix" && mode === "verify") {
  phase("Fix")
  const open = listOf(input.open)
  if (open.length === 0) return { plan: PLAN_MD, segment, mode, error: "args.open is empty" }
  // After two full rounds a fix is reviewed by its delta only: a fourth full
  // pass over an unchanged diff finds nothing new and costs a round.
  // Under local-only nothing was pushed, so fixes live on local branches.
  const refFor = (branch) => (mergeMode === "local-only" ? branch : "origin/" + branch)
  const rangeFor = (item) => {
    const tip = refFor(item.branch)
    if ((item.round ?? 1) > FULL_DIFF_ROUNDS && item.lastVerifiedSha) return item.lastVerifiedSha + ".." + tip
    return FIX_MODE === "fix-prs" ? "origin/" + PLAN.fix.baseBranch + "..." + tip : (input.reviewTip ?? PLAN.head) + ".." + tip
  }
  const reviewThunks = open.map((item) => () => agent(
    preamble("Fix") +
    "You are a READ-ONLY adversarial reviewer of a fix before it merges (" + item.ref + ", branch " +
    item.branch + ", round " + (item.round ?? 1) + "). Fetch, then read git -C " + PLAN.repoPath +
    " diff " + rangeFor(item) + " and the code it touches. It claims to fix " +
    listOf(item.findingIds).join(", ") + "; read those rows. For each, say whether the diff really " +
    "fixes it and trace the path. Then hunt for NEW blocking problems the fix itself introduces: " +
    "callers it breaks, an error path it opens, a guard it removes while restoring another, races, " +
    "authorization gaps, money or recipient-count changes, tests that pass without exercising the " +
    "bug. Do not edit anything or comment on GitHub.\n\n" + SEVERITY_TEXT +
    "Return unit '" + item.ref + "'. Put one 'fixed: <ID>' or 'not fixed: <ID> because ...' line per " +
    "claimed finding in verdicts.",
    { phase: "Fix", model: "opus", label: "review " + item.ref, schema: REVIEW_SCHEMA }
  ))
  const qaThunk = () => agent(
    preamble("QA") + tipCheck() +
    "Pre-merge browser QA of these open fixes COMBINED: " +
    open.map((i) => i.ref + " (" + i.branch + ", fixes " + listOf(i.findingIds).join(", ") + ")").join("; ") +
    ". Read their finding rows first.\nCreate a worktree under " + PLAN.worktreeRoot + " detached at " +
    PLAN.head + ", then git merge --no-edit each of " +
    open.map((i) => refFor(i.branch)).join(", ") + " in that order (local merge " +
    "commits only; never push). Build the throwaway environment:\n" +
    PLAN.qa.throwaway.map((s, i) => (i + 1) + ". " + s).join("\n") + "\n\n" + laneCommon() +
    "Flows: for each claimed finding, drive the scenario that proved it and confirm it no longer " +
    "reproduces, then the nearest normal path still works, at desktop and 390." +
    (input.qaFlows ? "\nAlso:\n" + input.qaFlows : "") + "\n\nCleanup at the end:\n" +
    PLAN.qa.throwawayCleanup.join("\n") + "\nand remove the worktree.",
    { phase: "Fix", label: "QA fixes combined", schema: LANE_SCHEMA }
  )
  const thunks = PLAN.fix.preMergeVerify ? reviewThunks.concat([ qaThunk ]) : reviewThunks
  const results = await parallel(thunks)
  const reviews = open.map((item, i) => ({ ref: item.ref, branch: item.branch, round: item.round ?? 1, range: rangeFor(item), result: results[i] ?? null }))
  const qa = PLAN.fix.preMergeVerify ? (results[open.length] ?? null) : null
  const written = await ledger("Fix",
    "Apply these pre-merge verification results. A claimed finding with a 'fixed' verdict and no " +
    "failing QA flow keeps status 'fixing <ref>' and gains 'verified at <range>'; a 'not fixed' one " +
    "goes back to open with the reason. Add each new finding from a fix diff or the combined QA as " +
    "FIX-<k> with its severity and status open. Copy new nits to followups.md.",
    { reviews, qa })
  return {
    plan: PLAN_MD,
    segment,
    mode,
    reviews: reviews.map((r) => ({ ref: r.ref, range: r.range, findings: r.result ? r.result.findings.length : null })),
    qa: qa ? { passed: qa.passed, findings: qa.findings.length, blocked: qa.blockedFlows } : null,
    ledger: written,
    ownerQuestions: qa ? qa.blockedFlows.filter((b) => b.needsOwner).map((b) => b.flow + ": " + b.reason) : [],
    nextStep: written && written.openBlockingIds.length === 0
      ? (FIX_MODE === "fix-prs" && mergeMode === "local-only"
          ? "Local-only: the verified fixes stay on their local branches, no PRs exist and nothing is merged. " +
            "Report the verified local branches to " + PLAN.fix.mergeAuthorizer + ", then run segment 'gate' at the local tip."
          : FIX_MODE === "fix-prs"
          ? "Main thread: for each verified PR, get " + PLAN.fix.mergeAuthorizer + "'s explicit " +
            "authorization and run " + PLAN.fix.mergeCommand + " as its own call. Then run segment 'gate' at the new tip."
          : "Run segment 'gate' with the PR branch tip as expectedTip.")
      : "Blocking items remain: run 'fix' mode 'plan-batches', then 'apply' with revise: true, then " +
        "'verify' with round + 1 and lastVerifiedSha set to each branch's verified head."
  }
}

if (segment === "fix") {
  return { plan: PLAN_MD, segment, error: "fix mode must be plan-batches, apply or verify", usage }
}

if (segment === "gate") {
  phase("Gate")
  const gate = await agent(
    preamble("Gate") + tipCheck() +
    "Create a fresh worktree: git -C " + PLAN.repoPath + " worktree add --detach " + PLAN.worktreeRoot +
    "/" + PLAN.slug + "-gate " + PLAN.head + " (remove a stale one first), link the env file and " +
    "install. Run each command in order and report each as a row with its real output summarized:\n" +
    PLAN.gate.chain.join("\n") + "\nNotes: " + PLAN.gate.notes.join("; ") + "\n" +
    (PLAN.gate.change
      ? "Then record the cf:change gate for this tip, exactly as written:\n" + PLAN.gate.change + "\n"
      : "") +
    "Remove the worktree afterwards. green is true only if every row passed, counting a listed " +
    "flake's single retry.",
    { phase: "Gate", schema: GATE_SCHEMA }
  )
  const written = gate ? await ledger("Gate",
    "Append this run to gate-log.md as an integration-tip gate. If green is true, move each finding " +
    "whose status is 'fixing <ref>' and that carries 'verified at' to 'fixed <ref>' when the fix's " +
    "head commit is an ancestor of " + PLAN.head + " (git -C " + PLAN.repoPath + " merge-base " +
    "--is-ancestor); leave every other 'fixing' row as it is.", gate) : null
  return {
    plan: PLAN_MD,
    segment,
    gate,
    ledger: written,
    nextStep: gate && gate.green
      ? "Run segment 'qa' with the same expectedTip (args.lanes to limit it to lanes the latest fixes touch)."
      : "STOP: the gate is not green; route failures through segment 'fix'."
  }
}

if (segment === "qa") {
  phase("QA")
  const selected = listOf(input.lanes)
  const setup = listOf(PLAN.qa.setup).length > 0 ? [ SETUP_LANE ] : []
  const lanes = setup.concat(PLAN.qa.lanes.filter((l) => selected.length === 0 || selected.includes(l.id)))
  const carryForward = listOf(input.carryForward)
  if (carryForward.length > 0 && PLAN.tier !== "release") {
    return { plan: PLAN_MD, segment, error: "carry-forward is a release-tier option; rerun the lanes instead" }
  }
  // Lanes run one at a time: they share one database, one server and Docker.
  const laneResults = []
  let haltedBy = null
  for (const lane of lanes) {
    const body = lane.id === "setup" ? lane.prompt() : laneCommon() + laneSpec(lane)
    const result = await agent(preamble("QA") + tipCheck() + body, { phase: "QA", label: lane.id, schema: LANE_SCHEMA })
    laneResults.push({ lane: lane.id, result: result ?? null })
    const stops = result ? result.stopReasons : []
    if (!result || (lane.id === "setup" && (!result.passed || stops.length > 0))) {
      haltedBy = "lane " + lane.id + " failed or stopped; setup gates every lane"
      break
    }
    if (stops.some((s) => s.startsWith(SAFETY_PREFIX))) {
      haltedBy = "safety stop in lane " + lane.id
      break
    }
  }
  if (haltedBy) log("Stopping QA: " + haltedBy)
  const written = await ledger("QA",
    "Write these lane results into qa-report.md as a new round for this tip, after the earlier " +
    "rounds (oldest first). Findings get ID QA-<lane>-<k>, keep statuses of existing findings, and " +
    "mark an earlier finding fixed only if its lane reran and passed that flow. In the lane summary " +
    "table, a lane in carryForward reads 'carried from <sha>, needs owner approval in run-log.md'; " +
    "do not treat it as passed. Copy nits to followups.md.",
    { laneResults, carryForward, haltedBy })
  const needsOwner = laneResults.flatMap((l) => (l.result ? l.result.blockedFlows.filter((b) => b.needsOwner).map((b) => l.lane + ": " + b.flow + ": " + b.reason) : []))
  return {
    plan: PLAN_MD,
    segment,
    lanesRun: laneResults.map((l) => ({ lane: l.lane, passed: l.result ? l.result.passed : false })),
    haltedBy,
    ledger: written,
    ownerQuestions: needsOwner,
    nextStep: haltedBy
      ? "STOP: " + haltedBy + ". Bring the stop reason to the owner before any rerun."
      : written && written.openBlockingIds.length === 0 && laneResults.length === lanes.length
        ? "QA clean at this tip." + (carryForward.length > 0
            ? " Carried lanes " + carryForward.map((c) => c.lane).join(", ") + " need an OWNER APPROVAL " +
              "line each in run-log.md before 'handoff'."
            : "") + " Run segment 'audit' mode 'check'."
        : "Route blocking findings through 'fix', re-gate, then rerun the touched lanes with args.lanes."
  }
}

if (segment === "audit") {
  phase("Audit")
  if (mode === "apply") {
    const written = await ledger("Audit",
      "Apply these owner rulings from run-log.md to the severity column (and nothing else), then " +
      "write 'Severity audit: <tip>' with the ruling count in each file's header, even when there " +
      "are no rulings.",
      { tip: expectedTip, rulings: listOf(input.rulings) })
    return {
      plan: PLAN_MD,
      segment,
      mode,
      ledger: written,
      nextStep: written && written.openBlockingIds.length > 0
        ? "Reclassified items are now blocking: route them through 'fix', 'gate' and the touched lanes."
        : "Run segment 'handoff' with the same expectedTip."
    }
  }
  const audit = await agent(
    preamble("Audit") + tipCheck() +
    "Read-only. Read every row in " + FILES.review + " and " + FILES.qa + " whose severity is not " +
    PLAN.severity.levels[0].name + ". Re-check each against the scale, ignoring who can trigger it " +
    "and ignoring how the reviewer framed it. Any row whose scenario, if it happened, meets a higher " +
    "level is a candidate: give the higher level and the one-sentence reason. Report every ID you " +
    "checked.\n\n" + SEVERITY_TEXT,
    { phase: "Audit", model: "opus", schema: AUDIT_SCHEMA }
  )
  return {
    plan: PLAN_MD,
    segment,
    mode: "check",
    audit,
    ownerQuestions: audit ? audit.candidates.map((c) => c.id + ": " + c.from + " -> " + c.to + "? " + c.why) : [],
    nextStep: "Put each candidate to the owner with AskUserQuestion (recommend the higher level where " +
      "the scenario meets it). Record every ruling in run-log.md, then run 'audit' mode 'apply' with " +
      "args.rulings = [{ id, to, reason }] (empty when there are none)."
  }
}

if (segment === "handoff") {
  phase("Handoff")
  const carryForward = listOf(input.carryForward)
  const handoff = await agent(
    preamble("Handoff") + tipCheck() +
    "You are the single writer of " + FILES.handoff + ": rewrite it in full with the numbered " +
    "sections below. Read-only everywhere else. Never let an earlier version's verdict stand; decide " +
    "it again from the files.\n\n" +
    "Verdict. READY only if every one of these holds, else NOT READY with each failed item in reasons:\n" +
    "1. " + FILES.gate + " shows an integration-tip gate green at the tip.\n" +
    "2. " + FILES.review + " and " + FILES.qa + " have no row with severity " +
    PLAN.severity.blocking.join(" or ") + " and status open or fixing.\n" +
    "3. Both headers carry 'Severity audit: <tip>'.\n" +
    "4. " + FILES.qa + " has a result at the tip for every lane" +
    (carryForward.length > 0
      ? ", except these carried lanes, each of which needs its own line in " + FILES.runLog +
        " starting 'OWNER APPROVAL' that names the lane and its from-sha: " + JSON.stringify(carryForward) +
        ". A carried lane the main thread accepted without such a line is a failed precondition"
      : "") + ".\n\n" +
    "Sections, numbered, in this order:\n" +
    "1. Verdict: READY or NOT READY at the tip, with one bullet per failed precondition.\n" +
    "2. Status: tip, gate, counts per severity recomputed from rows, lanes at tip and carried, fixes merged, severity audit.\n" +
    "3. What the plan got wrong: every divergence and owner ruling in " + FILES.runLog + " that changes " +
    "a later step, each with the corrected command quoted in full.\n" +
    "4. Expected?: data-dependent effects the owner must rule on (counts, drift, QA judgment calls), " +
    "each with a choice.\n" +
    "5. Owner final-pass checklist, verbatim:\n" + PLAN.handoff.finalPass.map((f) => "  " + f).join("\n") + "\n" +
    "6. Diffs to read before merge. Compute them, do not copy them: take git diff --name-only " +
    PLAN.base + ".." + PLAN.head + ", keep paths under the risk areas " +
    JSON.stringify(PLAN.riskAreas) + " and " + JSON.stringify(PLAN.handoff.mustRead) + ", then add " +
    "every path each fix commit named in the ledgers actually changed (git show --name-only). Emit " +
    "git diff commands that together cover every kept path, and list them in diffCommands.\n" +
    "7. Follow-ups from " + FILES.followups + ", with issue links where filed.\n" +
    (listOf(PLAN.handoff.verbatimSections).length > 0
      ? "8. Copied verbatim from plan.md: " + PLAN.handoff.verbatimSections.join(", ") + ".\n"
      : "") +
    "No connection strings or secrets.",
    { phase: "Handoff", model: "opus", schema: HANDOFF_SCHEMA }
  )
  return {
    plan: PLAN_MD,
    segment,
    handoff,
    nextStep: handoff && handoff.verdict === "READY"
      ? "Main thread: send " + FILES.handoff + " to the owner and wait for their final pass and a go " +
        "or no-go. A no-go item becomes a finding and loops through fix, gate and qa."
      : "NOT READY: resolve handoff.reasons (owner approvals go in run-log.md), then rerun 'handoff'. " +
        "Do not edit owner-handoff.md by hand."
  }
}

return { plan: PLAN_MD, ran: "nothing", error: segment ? "unknown segment '" + segment + "'" : "missing args.segment", usage }
