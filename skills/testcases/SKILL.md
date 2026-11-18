---
name: cf:testcases
group: lanes
description: Runs just the deterministic regression lane of the change-fabric platform against a project's config. Compiles committed test-case suite files into browser steps, replays them inside an ephemeral browserless Chromium container, grades each case, and writes a CSV and Markdown report to the Desktop. Invocable directly for a standalone regression check.
---

# CF testcases

The standalone regression lane of the change-fabric platform. Runs only the
committed test cases; for the full five-lane release sweep use `cf:change`.

Trigger: `/cf:testcases [<target>] [--signoff]`.

A literal `full auto` or `auto` as the first or last word of the args is
stripped before parsing, with a one-line note that full auto is
already the default.

Question: do this repo's committed test cases still pass?

## Run it

From the target repo root (a repo carrying `CHANGE.md`):

```
ruby ~/.claude/cf/bin/change_run.rb testcases
ruby ~/.claude/cf/bin/change_run.rb testcases --suite checkout   # one suite or tag
ruby ~/.claude/cf/bin/change_run.rb testcases --signoff          # pass this skill's --signoff through
```

Pass `--signoff` to `change_run.rb` exactly when the skill invocation carried
it, so the grader gate (see Graded acceptance below) reads the run as
interactive.

This boots the app per `boot`, waits for its health signal, stands up one
ephemeral browserless Chromium container (digest-pinned, `--rm`, per cf:docker;
no host browser), loads every suite file `lanes.testcases.suites` names, runs
each selected case in its own browser context, tears everything down, writes the
report pair to `~/Desktop`, and records a `testcases` scope gate under the head
SHA. A `testcases`-scope record never satisfies the comprehensive merge gate;
only a full `cf:change` run does.

Nothing is generated at run time. A case's steps are compiled to browser
instructions by Ruby, so the same case at the same commit gives the same
verdict. That is the difference between this lane and `cf:qa`: `cf:qa` explores
and finds out what to test, this replays what was already decided.

## Write a case

Cases live in sidecar suite files beside the code they test, conventionally
`<dir>/<name>.cf-testcases.yml`, never inline in `CHANGE.md`. The full schema
is `reference/suite-file-spec.md`; the shape is:

```yaml
suite: checkout
cases:
  - id: guest-checkout-happy-path
    tags: [checkout, smoke]
    acceptance: >
      A guest can add an item and reach the confirmation page
      without creating an account.
    steps:
      - goto: /products/widget
      - click: "[data-test=add-to-cart]"
      - expect_text: { selector: "[data-test=cart-count]", equals: "1" }
      - goto: /checkout
      - fill: { selector: "#email", env: CHECKOUT_TEST_EMAIL }
      - click: "[data-test=place-order]"
      - expect_url: { contains: "/confirmation" }
```

Point `CHANGE.md` at it:

```yaml
lanes:
  testcases:
    suites: [ 'qa/*.cf-testcases.yml' ]
```

Check it before running the lane: `ruby ~/.claude/cf/bin/change_config.rb doctor`
reports an unreadable glob, an empty suite, a duplicate case or suite id, an
undefined persona, an unknown step
verb, a missing `acceptance`, a quarantine missing its reason or its date, and a
`gate_tags` entry no case carries.

A real credential never goes in a suite file. A `fill` reads its value from the
env var `env:` names, or polls a `code_source` endpoint from inside the
container for an out-of-band code. That fetch runs in the browser page, so
Chromium's Local Network Access check can block it from reaching a private
address such as `http://host.docker.internal:3925/otp` (`TypeError: Failed to
fetch`). Set `lanes.testcases.launch_args:
["--disable-features=LocalNetworkAccessChecks"]` in CHANGE.md (spec 0.16.0) to
launch the lane's browser with that flag.

### Run cases as different users

Name logins once in `CHANGE.md` and let a case pick one (suite_version 3):

```yaml
lanes:
  testcases:
    auth: { login_url: /login, email_env: QA_EMAIL, password_env: QA_PASSWORD }
    personas:
      admin:
        login_url: /login
        email_env: QA_ADMIN_EMAIL
        password_env: QA_ADMIN_PASSWORD
        expired_when: { probe_url: /api/me, expect_status: 401 }   # or { selector: "#signed-out" }
```

```yaml
suite_version: 3
cases:
  - id: admin-sees-users
    persona: admin
```

`auth:` is the `default` persona; `persona: anonymous` never logs in. Each
persona logs in once per run and its session is seeded into each of its cases,
so those cases share one server-side session: a case that logs out affects the
ones after it. Only a persona that declares `expired_when` (a `selector`
visible only when logged out, or a `probe_url` with `expect_status`) is checked
for a mid-case session end; without it a lost session just fails the case.
When the probe fires, the persona logs in again once and the case replays from
its last `goto`, unless that would repeat an action
such as a click or fill, which fails the case `auth_interrupted` unless it sets
`safe_retry: true`. A logout test sets `expects_logout: true` to turn the probe
off. Details are under Sessions in the suite-file spec.

## Read the output

One finding per case. A passing case reports its `acceptance` sentence; a
failing one names the step that failed and why. The Markdown report also
carries a table pairing each case's acceptance criterion with the verdict its
steps produced.

A failing case fails the lane, and therefore the gate, exactly like every other
lane. If a case is failing for a reason that is not a regression, fix the case
in the repo rather than working around the gate: a case nobody trusts is worse
than no case. `gate_tags` exists for the one legitimate version of that, staged
adoption of a brand-new suite whose cases should report before they gate.

### Evidence

Reports land on the Desktop, or in `--out DIR`
(`change_run.rb testcases --out DIR`). Each run also writes
`<out>/testcases-<run-id>/`, mounted into the browser container while the
cases run:

- `cases/<suite>/<id>/attempt-<n>/start.json`, written before the call.
- `step-NNNN-a.json` per step, with the step's result, console errors and
  failed requests, checkpointed while the case runs; `failure.png` when a step
  fails and `final.png` at the end; a `screenshot` step's image as `shot-*.png`.
- `result.json` once the call returns. A call that never returns (killed on
  its budget, a browser crash) leaves `termination.json` instead, and the case
  is `partial_evidence`, with every step it checkpointed.
- `case-results.jsonl`, one record per case: key, persona, status (`pass`,
  `fail`, `auth_interrupted`, `partial_evidence` or `skipped`), each attempt
  with its outcome and evidence dir, duration, commit and run id.

A retry keeps every attempt's dir, so a fail-then-pass case shows both.

The run dir also gets `report.html` (each case's status, persona, duration,
acceptance verdict, its last 10 runs, and its screenshots linked relatively, so
the dir can be copied anywhere) and `junit.xml` (one `testsuite` per suite) for
CI. Every case result is appended to a history ledger outside the repo,
`~/.claude/cf/testcases/<project>/<repo>/[<app>/]history.jsonl`. The report flags a case as
newly failing when the last run that executed it passed, and as flaky when it
passed only after a failed attempt. A skipped case, and a case in the history
this run did not select, are listed on their own and never count as failing.

## Quarantine a flaky case

A case that is genuinely flaky can be time-boxed out of the gate instead of
deleted or left red every run:

```yaml
  - id: flaky-payment-redirect
    quarantined: true
    quarantine_reason: the sandbox gateway drops one redirect in twenty
    quarantine_until: 2026-09-15
```

It still runs, still reports, and still shows its verdict; only its power to
fail the gate is suspended, and only until that date. Both companion keys are
required, and a reason or a date without `quarantined: true` is rejected, since
it reads as a live quarantine and is not one.

Quarantine is never permanent. On `quarantine_until` the shield lapses on its
own and the case gates again, with no second action from anybody. `doctor`
warns once the expiry is within a week and errors once it has passed; the lane
adds a `warn` finding for a lapsed one, because the file now claims a shield
that is not there. The report names the reason and the date beside the case,
so the debt is visible rather than buried.

Prefer fixing the case. `gate_tags` is for staged adoption of a whole new
suite; quarantine is for one known-flaky case with a date on it.

## Graded acceptance

Each case gets a second finding: its `acceptance` prose graded against what the
run observed (the final url, the page title, the visible text, and the step
record). A page can satisfy every selector assertion and still do the wrong
thing, which is the failure a selector cannot see.

That verdict can fail the gate. It is deliberately not capped at warn: a
criterion whose failure cannot fail anything is a comment. `gate_tags` softens
it exactly as it softens a step failure. An `unclear` verdict (the grader
declined to decide) fails the gate under full auto, the default, since an
unattended run cannot read a warn and nobody else will; under `--signoff` it
stays a warn, for the human reading the report to judge.

If a verdict is wrong, the escape hatch is the sha-scoped override this repo
already has, not a new one:

```
ruby ~/.claude/cf/bin/change_override.rb <head sha> --reason '<why>'
```

By default, print that command with the head SHA filled in at the end of the
report, for the user to run from their own terminal; no question. Under
`--signoff`, offer it as an `AskUserQuestion` at the moment of failure instead.
In CI it fails closed and stays failed: `change_override.rb` refuses without a
real terminal by design, so no agent can record it for a human.

Under away mode the default applies: the command is reported, never run,
because `change_override.rb` refuses without a real terminal.

Grading is the one part of this lane that is not deterministic, and it is kept
in one named place for that reason. It uses the `claude` CLI by default,
`CF_ACCEPTANCE_GRADER` to point at something else, and `CF_SKIP_ACCEPTANCE_GRADING=1`
to turn it off. With no grader reachable, the lane reports one finding naming
what did not run, never a pass: unjudged prose is never laundered into a
checked criterion. Under full auto, the default, that finding fails the gate,
the same as an `unclear` verdict; pass `--signoff` to run this interactively
and have it warn instead.

## Unattended gates

| ID | Action | Requires | When unmet |
|---|---|---|---|
| TC-1 | Pass the testcases lane gate | A grader is reachable and every `acceptance` verdict is decided (not `unclear`) | Fails the gate under full auto, the default; stays a `warn` under `--signoff` |

## Failure modes

- Docker unavailable, or an image cannot be pulled: exits 2 and names the cause;
  report and stop.
- No `CHANGE.md` with a `change_config:` block: the repo is not
  change-fabric-integrated. Say so.
- A suite glob matching no file, or a suite that fails to parse: a named failing
  finding, never a quietly empty run. A gate that checks zero cases reports
  green for the same reason one that checks everything does.
- browserless never becomes ready: the lane records a failing finding rather
  than crashing the run.
- Grader missing, or a verdict comes back `unclear`: fails the gate under full
  auto, the default; stays a `warn` under `--signoff` [TC-1].
