---
name: cf:qa
group: lanes
description: Ad hoc QA smoke-test runner. Scopes a browser test plan from a natural-language target (a pull request, a described feature, a flow), clarifies ambiguity, then executes the plan against an ephemeral browserless Chromium container and reports findings, posting them as GitHub PR comments by default, and writes a passing flow out as a test-case suite file. `--suite <suite-or-tag>` instead replays committed cases deterministically, with no scoping model in the loop; invocable directly.
---

# CF QA Runner

Ad hoc, model-scoped smoke testing. Never auto-fires; invoke directly with a
natural-language target: a PR (number, URL, or description of one), a running
app or URL, or a semantically described feature or flow.

Distinct from `cf:change`: this skill is ad hoc, model-scoped, and
natural-language-driven, for exploratory UAT of a described flow. `cf:change` is
the deterministic, config-driven, comprehensive release-gate sweep (k6 load,
axe-core accessibility, OWASP ZAP pentest, and browserless responsive UX) that
reads a project's root `CHANGE.md` and runs unattended before a
release-affecting merge. Reach for `cf:qa` to investigate; reach for
`cf:change` to gate.

Doctrine: `cf:docker` applies. The browser runs in one dedicated, ephemeral
container per run (`docker run --rm ...`, digest-pinned image), never a host
daemon, never a reused long-lived container.

## Sign-off

Acts by default: posts findings comments, edits the `## Demo` section, and
writes promoted flows without asking. `--signoff` asks before each. A literal
`full auto` or `auto` as the first or last word of the args is stripped before
parsing, with a one-line note that full auto is already the default. Under
away mode `--signoff` is ignored and the run reports that it assumed the
default. Phase 2's clarifying questions are scoping, not sign-off, and stay.

## Two modes

`/cf:qa --suite <suite-or-tag>` is the deterministic regression mode. It runs
committed test cases and nothing else:

```
ruby ~/.claude/cf/bin/change_run.rb testcases --suite <suite-or-tag>
```

`--out DIR` puts the report pair and the run's evidence dir
(`testcases-<run-id>/`, per-attempt traces and screenshots, `report.html`
and `junit.xml`) there instead of on the Desktop. Point a stakeholder at
`report.html` and CI at `junit.xml`.

`--export pdf,video` adds `report.pdf` and one MP4 per case (title card, the
case's last attempt, step captions) to the run dir, with no paid call; see
`skills/testcases/SKILL.md` (Exports) for the disk budget. An export failure
never changes a case's verdict. Narration is never part of it: it is a
separate opt-in that needs a printed estimate and explicit approval first.

No scoping model, no clarifying round, no generated script: phases 1 to 4 are
skipped entirely. The selector matches a suite id or a case tag, and it is
repeatable. A selector matching nothing is a failing finding, never an empty
run. Report the lane's output and stop; there is nothing to promote, because
these cases are already committed.

## Film mode

`/cf:qa film --url <staging> --persona <name> --flag <key> --steps "<clicks>"
[--save-suite <path>]` films one flag-gated flow on a deployed environment,
signed in as a persona, and leaves client UAT evidence: an MP4, `report.html`,
`report.pdf`, `junit.xml` and a pass/fail `checklist.md`. Nobody writes a
suite by hand; this session drafts it. No paid API call is made: the
acceptance sentence is graded by the lane's own grader (the local `claude -p`
CLI). With no grader, or `CF_SKIP_ACCEPTANCE_GRADING=1`, a run whose every
step passed is still a pass and the checklist marks the criterion not graded.
`--persona` defaults to `anonymous`; lane `basic_auth` applies to both steps.

What the project configures once:
- The persona under `lanes.testcases.personas` in CHANGE.md, the same block as
  `auth:`. An OIDC login that spans pages uses its `steps:` form (each step a
  `url`, `fields` with `env:` names, a `submit_selector`, a
  `wait_for_selector`). Its `env:` names come from the environment, else from
  the project's cf secret store (stage each with `cf:secret-intake`). Never ask
  for a value in chat, and never print one.
- How the flag is confirmed, on the command line: `--flag-probe PATH` (an app
  route, `{flag}` replaced by the key, whose body must contain `--flag-expect`,
  default `true`) or `--flag-selector SEL` (an element shown only with the flag
  on). With neither, ask which one.

Steps, all through `ruby ~/.claude/cf/bin/change_qa_film.rb`:
1. Draft. Run `probe --url URL --persona NAME [--steps draft.yml]`. It signs
   in, runs the draft so far, and prints each step's result and a snapshot of
   the page (title, url, headings, visible controls, each with a selector).
   Write the next steps of `draft.yml` from the snapshot and the `--steps`
   description, then probe again, until the whole description passes. A draft
   is `acceptance:` (the sentence the client signs off on) and `steps:` in the
   suite verbs (`skills/testcases/reference/suite-file-spec.md`), each with an
   optional `check:`, its plain checklist line. Start it with a `goto`.
   A count that must match a list is `capture` then `expect_equal`.
2. Film. Run `run --url URL --persona NAME --flag KEY --draft draft.yml
   (--flag-probe PATH | --flag-selector SEL) [--out DIR] [--save-suite PATH]`.
   The flag check is the first assertion; the case runs through the testcases
   lane with video on, so the login, evidence and acceptance grading are the
   lane's. It prints JSON naming every file; exit 0 is a pass, 3 a fail. It
   records no gate.
3. Report the status, the checklist lines and the file paths. On a pass,
   `--save-suite` writes the case (suite id from the file name, never over an
   existing file); say that `lanes.testcases.suites` must cover it.

Everything below is the exploratory mode, reached by a natural-language target.
Use it to find out what to test; use `--suite` to check it still works.

## Phase 1: Scope the plan (background, opus)

Spawn a background Agent (`model: "opus"`) with the raw target description.
Task it to:
- Identify the target: a PR (read the diff and description with the GitHub
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
- Write every selector in the plan in the syntax phase 4's compiler accepts,
  as stated once in `skills/testcases/reference/suite-file-spec.md` (Step
  verbs): plain CSS, `::-p-` selectors, and the `text=`, `:has-text`,
  `:text-is`, `>> nth=N` forms listed there, nothing else. A cross-page
  check (a count on one page equals a list length on another) is a
  `capture` then `expect_equal`, never `eval`.
- Fill a `screenshot` block alongside them, so the before/after phase needs no
  second relevance call of its own. Set `screenshot.ui_surface` true when the
  change touches a user-facing or browser-drivable surface, false when there is
  no reachable UI to photograph. This is the same judgment `cf:drive`'s Haiku
  relevance gate already applies; do not add a separate relevance check
  anywhere.

  ```
  screenshot: {
    ui_surface: true|false,
    is_pr: true|false,
    pr_number: <int or null>,
    base_ref: "<the PR's base branch, or null>"
  }
  ```

Run this phase even for a target that looks simple; phases 2 to 5 all consume
its output, and the cost is one background agent call.

## Phase 2: Clarify (foreground)

If `open_questions` is empty, or every question has an obvious default given
the context (a single running app, an unambiguous flow), skip straight to
phase 4. Do not ask questions for ceremony.

Otherwise call `AskUserQuestion` with up to four of the highest-value
`open_questions` in one batched call. Fold the answers into the plan.

Under away mode, skip this question, proceed on the inferred plan (the
highest-value guess for each open question), and report the assumption.

## Phase 3: Refine (background, opus, max 3 rounds)

An answered round can surface new ambiguity. Spawn another background Agent
(`model: "opus"`) to integrate the round's answers into the plan and report
any fresh `open_questions`. Empty means proceed to phase 4. Non-empty means
repeat phase 2, then this phase, incrementing the round counter. Stop after
round 3 regardless of remaining ambiguity, proceed with the plan's current
best guesses, and note the unresolved points in the final report.

## Phase 4: Execute (background, sonnet)

Execution is deterministic. The model's job is to turn the plan into
declarative steps; it never writes the browser automation. `scripts/change_flow_compiler.rb`
compiles those steps into the browserless payload in pure Ruby, so the same
flow file run twice produces the same JS and the same verdict, and the flow
survives the session as a file instead of evaporating with the transcript.

Spawn a background Agent (`model: "sonnet"`) with the finalized plan. Task it
to:
1. Start the application under test if not already running, per the plan's
   setup step, and wait for a real readiness signal (a 200 from a health or
   root route), never a fixed sleep.
2. Write each plan flow as a flow file: a mapping with `base_url` and `steps`,
   each step one verb. Actions: `goto`, `click`, `fill` (value from `env`, a
   literal `value`, or a `code_source`), `select`, `press`, `wait_for`,
   `screenshot` (`full_page: true`, per-capture `viewport: { width, height }`),
   `capture` (`{ selector, as: name, kind: text|number|count }`). Assertions:
   `expect_visible`, `expect_hidden`, `expect_text`, `expect_url`,
   `expect_status`, `expect_count`, `expect_equal` (`{ var, selector, kind }`
   or `{ var, equals_var }`). A flow-level `viewport: { width, height }` sizes
   the page; any step takes `timeout_ms`, beside the verb or inside its
   mapping (use 30000 or more for a cold start).

   Use only the selector syntax in
   `skills/testcases/reference/suite-file-spec.md` (Step verbs); any other
   Playwright form is refused at compile time.

   ```yaml
   base_url: http://127.0.0.1:3000
   viewport: { width: 1280, height: 800 }
   steps:
     - goto: /products/widget
     - click: "button:has-text('Add to cart')"
     - expect_text: { selector: "[data-test=cart-count]", equals: "1" }
     - fill: { selector: "#email", env: QA_EMAIL }
     - expect_url: { contains: "/confirmation" }
     - goto: /dashboard
     - wait_for: { selector: "[data-test=summary]", timeout_ms: 30000 }
     - capture: { selector: "[data-test=open-count]", as: open, kind: number }
     - click: "text=Open orders"
     - expect_equal: { var: open, selector: "tr.order", kind: count }
     - screenshot: { name: orders, full_page: true }
   ```
3. Run each flow with `ruby scripts/change_flow_run.rb <flow.yml>`, which
   starts the ephemeral browserless Chromium container, digest-pinned per
   `cf:docker`, runs the compiled payload, and tears the container down even
   on failure. Never launch or reuse a host-level browser process, and never
   hand-write Playwright in place of the compiler. `--dump` compiles without
   running, for reviewing a flow before it runs. For a local HTTPS dev app
   behind a reverse proxy, pass `--add-host HOST:host-gateway` (the container
   cannot read the host's /etc/hosts) and `--ignore-https-errors` (the
   container lacks the local dev CA); the latter is refused unless the
   base URL is a local host. When the repo's CHANGE.md profile already sets
   `boot.add_hosts` and `boot.ignore_https_errors` (spec 0.15.0), pass
   `--profile NAME` instead; it also supplies `boot.target_url` as the base
   URL. Extra Chromium flags go in `--launch-arg FLAG` (repeatable), or come
   from the profile's `lanes.testcases.launch_args` (spec 0.16.0). The usual
   one is `--launch-arg --disable-features=LocalNetworkAccessChecks`, when a
   `code_source` fetch from the page to a private address such as
   `host.docker.internal` fails with `TypeError: Failed to fetch`.
4. Reach for the `eval:` escape hatch only when no verb covers the check, and
   say so in the findings: a compiled `eval` step is marked raw JS precisely
   so a reader can see where the declarative contract was abandoned.
5. If a flow's assertion could plausibly match more than one element, treat
   that as a plan gap, not a judgment call: report it as a finding instead of
   silently picking one.
6. Return findings: one line per flow, pass or fail, with the concrete
   evidence backing any failure (the failing step's label and error, plus the
   screenshot from any `screenshot` step).

Never paste a credential into a flow file or a finding. A value that is a
secret comes from `env:`, which is read on the host and reaches only the
container; the compiler's own redacted view is what may be reported.

## Phase 5: Before/after screenshots (deterministic)

What visibly changed on screen between the base ref and HEAD, captured as
before/after pairs. Deterministic: no model decides which routes to shoot.

Skip this phase, and say plainly that it was skipped and why, in any of these
cases:
1. The repo has no root `CHANGE.md`. There is no route or viewport list to work
   from. This matches `changePrompt()` in `skills/drive/reference/workflow.js`,
   which already self-skips the same way.
2. `screenshot.ui_surface` from phase 1 is false. Two full app boots are not
   worth spending on a backend-only diff.
3. No second git state is available: a live-app-only target, or a bare
   description with no diff. A plain skip, not an error, and not a run failure.

Otherwise follow `~/.claude/skills/cf:screenshot/SKILL.md` in full: determine the
base ref, capture both sides, diff every route/viewport pair, keep only the
pairs that actually differ, upload the survivors, and write the `## Demo` PR
body edit (under `--signoff`, ask first). This phase inherits cf:screenshot's
own upload-failure rule as-is [QA-1]: any pair that failed to upload means no
Demo edit at all, reported with the local file paths instead, same as a
standalone cf:screenshot run. Use `screenshot.pr_number` and
`screenshot.base_ref` from phase 1 rather than re-deriving them. Zero differing
pairs is a successful outcome: report it and skip the upload and the edit.

## Phase 6: Report

Summarize findings in the chat response first.

If the target correlates to a real GitHub pull request, findings also land
as a PR validation comment, through whichever GitHub interface (`gh` CLI
or GitHub MCP tools) is available:
- Group findings into at most 3 comments of at most 640 characters each,
  split by semantic area (e.g. auth flow, checkout flow) or by giving each
  comment its own focused re-run's subset. Findings only: no preamble, no
  closing remarks, no restating the plan.
- Post the comment(s). Under `--signoff`, first call `AskUserQuestion` with
  an executive summary of each comment and ask whether to post, edit, or skip.

## Phase 7: Promote the flow (foreground)

Exploratory QA used to end as a transcript: the flow worked out by hand
evaporated with the session, and the next regression in it went uncaught. This
phase ends it as an artifact instead.

Run only after a flow actually passed in phase 4. Skip it for a flow that
failed: a case is written from a flow known to work, and promoting a red one
commits the bug as the expected behavior.

For each passing flow:
1. Render it as a suite file:

   ```
   ruby ~/.claude/cf/bin/change_flow_run.rb <flow.yml> --promote \
     [--suite <suite-id>] --case-id <case-id> --acceptance "<one sentence>" --tags smoke \
     [--persona <name>]
   ```

   `--suite` defaults to the flow file's name (`checkout.flow.yml` is suite
   `checkout`). When the flow opens with a login that matches a persona in
   `lanes.testcases.personas` (or the lane's `auth:`, the `default` persona),
   the case gets `persona: <name>` and those login steps are dropped, because
   the lane logs each persona in once per run. `--persona <name>` names it
   outright.

   The renderer parses its own output back through the suite parser before
   printing, so what it emits is a file the `testcases` lane will accept. It
   drops the flow's `base_url`: the lane supplies that per profile, and a case
   pinned to one machine's localhost only runs on that machine. A flow's
   `retries` is carried only when the flow also sets `safe_rerun: true`,
   because a rerun replays every action of the failed attempt; otherwise it is
   dropped with a note on stderr.
2. `--acceptance` is the sentence a person would use to say the flow worked,
   not a restatement of the steps. It is graded against the run by `cf:change`,
   and that verdict can fail the gate, so write what actually matters and
   nothing you would not want enforced.
3. Create the file if it does not exist yet (conventionally
   `qa/<suite>.cf-testcases.yml`, next to the code it tests). If it already
   exists, append the case to its `cases:` list instead of overwriting the
   file. Never overwrite an existing case id without `--signoff`: on a
   collision, skip and report the rendered YAML. Under `--signoff`, show the
   YAML and path and ask whether to write, edit, or skip.
4. Never commit it, never open a PR for it. Report every written path so the
   user can drop a case they do not want.
5. If the file is new, say that `CHANGE.md` needs `lanes.testcases.suites` to
   name a glob covering it, or the case is committed and never runs.

## Unattended gates

| ID | Action | Requires | When unmet |
|---|---|---|---|
| QA-1 | Edit the PR body's `## Demo` section (phase 5) | Inherits SS-1: every upload succeeded | No edit; report the local file paths instead, same as cf:screenshot |

## Failure modes

- Docker unavailable, or the browserless image cannot be pulled: report this
  and stop. Do not silently fall back to an unmanaged host browser.
- The target cannot be determined as anything testable (no PR, no reachable
  app, no identifiable feature): ask, do not guess.
- The app under test never becomes ready: report the timeout as a finding,
  not a crash.
- The before/after phase cannot determine a second git state, or the repo has
  no `CHANGE.md`: the phase skips and says so; it is not a run failure.
- Any screenshot pair fails to upload: no Demo edit follows [QA-1].
