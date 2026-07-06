---
name: pst:qa
description: Ad hoc QA smoke-test runner. Scopes a Playwright test plan from a natural-language target (a pull request, a described feature, a flow), clarifies ambiguity, then executes the plan against an ephemeral browserless Chromium container and reports findings, optionally as GitHub PR comments; invocable directly.
---

# PST QA Runner

Ad hoc, model-scoped smoke testing. Never auto-fires; invoke directly with a
natural-language target: a PR (number, URL, or description of one), a running
app or URL, or a semantically described feature or flow.

Doctrine: `pst:docker` applies. The browser runs in one dedicated, ephemeral
container per run (`docker run --rm ...`, digest-pinned image), never a host
daemon, never a reused long-lived container.

## Phase 1: Scope the plan (background, opus)

Spawn a background Agent (`model: "opus"`) with the raw target description.
Task it to:
- Resolve the target: a PR (read the diff and description with the GitHub
  tools), a semantic feature description (locate the relevant routes,
  components, and existing tests in the repo), or a live app/URL.
- Produce a test plan, returned as structured data, not prose: `flows` (each
  with concrete assertions, precise enough that phase 4 never has to invent a
  disambiguation rule - name the scope, e.g. "the nav link", when more than
  one element could plausibly match), `setup` (env vars, seed data, accounts,
  how to boot the app under test and how to know it is ready), and
  `open_questions` (anything genuinely ambiguous: which environment, which
  account or role, destructive vs read-only actions, viewport, whether auth
  is required).

Run this phase even for a target that looks simple; phases 2 to 4 all consume
its output, and the cost is one background agent call.

## Phase 2: Clarify (foreground)

If `open_questions` is empty, or every question has an obvious default given
the context (a single running app, an unambiguous flow), skip straight to
phase 4. Do not ask questions for ceremony.

Otherwise call `AskUserQuestion` with up to four of the highest-value
`open_questions` in one batched call. Fold the answers into the plan.

## Phase 3: Refine (background, opus, max 3 rounds)

An answered round can surface new ambiguity. Spawn another background Agent
(`model: "opus"`) to integrate the round's answers into the plan and report
any fresh `open_questions`. Empty means proceed to phase 4. Non-empty means
repeat phase 2, then this phase, incrementing the round counter. Stop after
round 3 regardless of remaining ambiguity, proceed with the plan's current
best guesses, and note the unresolved points in the final report.

## Phase 4: Execute (background, sonnet)

Spawn a background Agent (`model: "sonnet"`) with the finalized plan. Task it
to:
1. Start the application under test if not already running, per the plan's
   setup step, and wait for a real readiness signal (a 200 from a health or
   root route), never a fixed sleep.
2. Launch the ephemeral browserless Chromium container, digest-pinned per
   `pst:docker`, and connect Playwright over CDP to it. Never launch or reuse
   a host-level browser process in place of the container.
3. Drive each plan flow with Playwright, asserting its concrete checks. If a
   flow's assertion could plausibly match more than one element, treat that as
   a plan gap, not a judgment call: report it as a finding instead of
   silently picking one. Capture a screenshot plus console/network state on
   every failure.
4. Tear the container down even on failure or crash; ephemeral means
   ephemeral regardless of outcome.
5. Return findings: one line per flow, pass or fail, with the concrete
   evidence backing any failure.

## Phase 5: Report

Summarize findings in the chat response first.

If the target correlates to a real GitHub pull request, findings may also
land as a PR validation comment, through whichever GitHub interface (`gh` CLI
or GitHub MCP tools) is available:
- Group findings into at most 3 comments of at most 640 characters each,
  split by semantic area (e.g. auth flow, checkout flow) or by giving each
  comment its own focused re-run's subset. Findings only: no preamble, no
  closing remarks, no restating the plan.
- Call `AskUserQuestion` with an executive summary of each comment (the full
  text, if the question format allows it) and ask whether to post, edit, or
  skip. Never post without an explicit go-ahead from this call.
- Only after approval, post the comment(s).

## Failure modes

- Docker unavailable, or the browserless image cannot be pulled: report this
  and stop. Do not silently fall back to an unmanaged host browser.
- The target resolves to nothing testable (no PR, no reachable app, no
  identifiable feature): ask, do not guess.
- The app under test never becomes ready: report the timeout as a finding,
  not a crash.
