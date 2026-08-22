---
name: cf:testcases
description: Runs just the deterministic regression lane of the change-fabric platform against a project's config. Compiles committed test-case suite files into browser steps, replays them inside an ephemeral browserless Chromium container, grades each case, and writes a CSV and Markdown report to the Desktop. Invocable directly for a standalone regression check.
---

# CF testcases

The standalone regression lane of the change-fabric platform. Runs only the
committed test cases; for the full five-lane release sweep use `cf:change`.

Trigger: `/cf:testcases [<target>]`.

Question: do this repo's committed test cases still pass?

## Run it

From the target repo root (a repo carrying `CHANGE.md`):

```
ruby ~/.claude/cf/bin/change_run.rb testcases
ruby ~/.claude/cf/bin/change_run.rb testcases --suite checkout   # one suite or tag
```

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
reports an unreadable glob, an empty suite, a duplicate case id, an unknown step
verb, a missing `acceptance`, a quarantine missing its reason or its date, and a
`gate_tags` entry no case carries.

A real credential never goes in a suite file. A `fill` reads its value from the
env var `env:` names, or polls a `code_source` endpoint from inside the
container for an out-of-band code.

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
it exactly as it softens a step failure. An `unclear` verdict is a warn, because
a grader that declined to decide has not found a defect.

If a verdict is wrong, the escape hatch is the sha-scoped override this repo
already has, not a new one:

```
ruby ~/.claude/cf/bin/change_override.rb <head sha> --reason '<why>'
```

In an interactive session, offer that as an `AskUserQuestion` at the moment of
failure. In CI it fails closed and stays failed: `change_override.rb` refuses
without a real terminal by design, so no agent can record it for a human.

Under away mode, skip the offer, fail closed the same way CI does, and report
that the override was not offered. An away session could not act on an answer
regardless: `change_override.rb` refuses without a real terminal by design.

Grading is the one part of this lane that is not deterministic, and it is kept
in one named place for that reason. It uses the `claude` CLI by default,
`CF_ACCEPTANCE_GRADER` to point at something else, and `CF_SKIP_ACCEPTANCE_GRADING=1`
to turn it off. With no grader reachable, the lane reports one `warn` naming
what did not run: unjudged prose is never laundered into a checked criterion,
and a machine with no grader installed is not a failed run.

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
