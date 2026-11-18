# Test-case suite file specification

Suite version: 2

The schema for a change-fabric test-case suite file: the sidecar YAML the
`testcases` lane loads and replays.

This is a different document from `CHANGE.md`. A suite file lives beside the
code it tests, is authored by whoever owns that flow, and changes on that flow's
own schedule, so it carries its own registry (`ChangeSuiteSchema` in
`scripts/change_suite_schema.rb`) and its own drift test
(`test/change_suite_schema_spec_test.rb`) rather than a section of the
`CHANGE.md` frontmatter spec. A new step verb is a compiler change, not a
governance-schema change, and nothing here should ever require a
`ChangeSchema::VERSION` bump.

## Where a suite file lives

Beside the code it covers, named `<name>.cf-testcases.yml` by convention, and
referenced from `CHANGE.md` by glob:

```yaml
# CHANGE.md frontmatter
lanes:
  testcases:
    suites: [ 'qa/*.cf-testcases.yml' ]
```

Never inline in `CHANGE.md`. Cases belong with the flow they check, are
reviewed by the people who own that flow, and would otherwise turn one
governance file into every team's assertion dump.

## Suite version

A suite file declares the format version it was written against in a top-level
`suite_version` integer. A file with none is version 1. The installed toolkit
reads every version up to its own (the "Suite version" line above, and
`ChangeSuiteSchema::SUITE_VERSION` in code; `doctor` prints it). Each version
only adds optional fields, so an older file always loads on a newer install.

| Version | Adds |
| --- | --- |
| 1 | The original field set: `suite`, and on each case `id`, `tags`, `acceptance`, `retries`, `quarantined`, `quarantine_reason`, `quarantine_until`, `steps`. |
| 2 | `suite_version`, `cases[].timeout_ms`, `cases[].safe_rerun`. From this version on the loader is strict (below). |

The loader is strict. An unknown top-level or case key is refused by name, and
a key newer than the file's declared `suite_version` is refused with the version
that adds it, so set `suite_version` to the highest version whose keys the file
uses.

Older installs. An install from suite version 2 on refuses a file that declares
a newer version with `suite_version N needs a newer cf toolkit; pull and run
ruby install.rb`. An install from before suite version 2 does not know the key
at all and silently ignores `suite_version` and every newer key, running the
case without them; a suite that relies on a newer key needs every runner on a
current install.

## Fields

The Since column is the `suite_version` that added the field.

| Field | Type | Required | Description | Since |
| --- | --- | --- | --- | --- |
| `suite_version` | integer | no (default 1) | The suite-file version this file was written against. Checked before any other key: a version above the installed one fails with the update message, and a key newer than the declared version fails naming the version that adds it. | 2 |
| `suite` | string | yes | The suite's id. Names it in a report and in a tag or suite selection. Not derived from the filename, so moving the file never silently renames the suite. | 1 |
| `cases[].id` | string | yes | This case's id, unique within the suite. Reported as `<suite>/<id>`, which is what a failing gate names. | 1 |
| `cases[].tags` | list of string | no | Free-form tags. `lanes.testcases.tags` selects which cases run; `lanes.testcases.gate_tags` selects which may fail the gate. | 1 |
| `cases[].acceptance` | string | yes | What a human means by "working" for this case, in plain English. Required, and rendered beside its verdict in the report. A selector assertion cannot catch a page that renders every expected element and still does the wrong thing; this sentence is graded against what the run observed, and that verdict can fail the gate. Write what actually matters, not a restatement of the steps. | 1 |
| `cases[].retries` | integer | no (default 0) | How many times to re-run this case while it fails. Zero by default: a case that only passes sometimes is a finding, not a scheduling problem. A case that passed only after a retry is recorded as a pass with `flaky` beside it and its attempt count, never laundered into a clean first-run pass. A rerun replays every step of the failed attempt, including any click or submit that already took effect, so `retries` above zero is refused unless the case also sets `safe_rerun: true`. | 1 |
| `cases[].safe_rerun` | boolean | yes when `retries` is above 0 | Says a whole-case rerun is safe: replaying the case's earlier actions after a failure cannot double-submit anything that matters. Without it `retries` is refused at load. | 2 |
| `cases[].timeout_ms` | integer (1000..600000) | no | This case's browserless call budget. Each case runs in its own call; without this the lane derives the budget from the sum of the steps' timeouts plus 5000 ms per `goto`, never below 115000. | 2 |
| `cases[].quarantined` | boolean | no (default false) | Time-boxes this case out of the gate. It still runs and still reports; its failure just cannot fail the gate, and only until `quarantine_until`. Requires both companions below. | 1 |
| `cases[].quarantine_reason` | string | yes when quarantined | Why this case is quarantined, in plain English. Required, because without it nobody can tell a known flake from a real defect somebody muted. | 1 |
| `cases[].quarantine_until` | date (`YYYY-MM-DD`) | yes when quarantined | The day the quarantine ends. Quarantine is never permanent. The shield has already lapsed on this date, and the case gates again from then on with no second action from anybody. | 1 |
| `cases[].steps` | list of mapping | yes | The ordered steps. Each entry is a mapping naming exactly one verb below, plus an optional `timeout_ms`. The walk stops at the first failing step, because everything after it runs against a page that is no longer in the state the case described. | 1 |

## Step verbs

Compiled by `ChangeFlowCompiler` (`scripts/change_flow_compiler.rb`), which
owns this vocabulary; the list here is that compiler's, not a second copy of
it. Every verb takes either a scalar shorthand (`click: "#go"`) or a full
mapping (`click: { selector: "#go" }`). A `timeout_ms` may sit beside the
verb or inside its mapping (`wait_for: { selector: "#app", timeout_ms: 30000 }`);
the one beside the verb wins.

A selector is a plain Puppeteer selector (CSS, `::-p-text(...)`,
`::-p-xpath(...)`), or one of these text and position forms, parsed by
`scripts/change_flow_selector.rb`: `text=Save` (innermost element whose text
contains it, skipping `<head>`, `<title>`, `<script>`, `<style>`,
`<noscript>`, and `<template>` content), `text="Save"` (exact), a trailing
`:has-text("x")` or `:text-is("x")` on a CSS selector, and a trailing
`>> nth=N` (0-based, `-1` is the last match). Text compares with whitespace
collapsed. Other `>>` chains, a mid-selector `:has-text`, or mixing these
forms with `::-p-` are refused at compile time; the same characters inside a
quoted attribute value (`a[title="Next >>"]`) are plain CSS.

| Kind | Verb | What it does |
| --- | --- | --- |
| action | goto | Navigates to a url or a site-relative path, under an optional `wait_until` load state. |
| action | click | Waits for the selector, then clicks it. |
| action | fill | Types a value into a field. Exactly one source: `env` (an env var name, read on the host), `value` (a literal already visible in the file), or `code_source` (an HTTP endpoint polled from inside the container). |
| action | select | Selects an option by value in a `select` element. |
| action | press | Presses a key, optionally after focusing a selector. |
| action | wait_for | Waits for a selector, a url fragment, or a navigation load state. |
| action | screenshot | Captures a named screenshot at this point in the flow. `full_page: true` captures the whole scrollable page; `viewport: { width, height }` resizes for this capture only. |
| action | capture | Reads a selector into a named variable: `{ selector, as: name, kind: text, number, or count }` (default `text`; `number` is the first number in the text, commas ignored). |
| assertion | expect_visible | The selector must be present and visible. |
| assertion | expect_hidden | The selector must be absent or hidden. |
| assertion | expect_text | The selector's text must `equals` or `contains` the expected string. |
| assertion | expect_url | The current url must `equals` or `contains` the expected string. |
| assertion | expect_status | The last navigation's HTTP status must equal the expected code, so a route that answers 500 with a rendered body is still a failure. |
| assertion | expect_count | The number of elements matching the selector must equal the expected count. |
| assertion | expect_equal | A captured `var` must equal a live read of `selector` (with `kind`) or a second captured `equals_var`. Compared as strings, so a captured number matches a count. A var no earlier step captures is refused at compile time. |
| escape hatch | eval | Raw JS, run as-is in the page. Marked as raw in the compiled step and labeled as such in the report, so a reader can see exactly where the declarative contract was abandoned. Reach for it last. |

## Secrets

A real credential never appears in a suite file. `fill` reads it from the
environment variable `env:` names, or resolves it inside the browser container
from a `code_source` endpoint (a dev inbox API, for an out-of-band code) so an
OTP is never read, stored, or logged on the host at all. Compiled steps carrying
a value read from an env var go to the container and nowhere else; the report
renders step labels and the acceptance prose, never the compiled payload.

## Quarantine

A case that is genuinely flaky can be time-boxed out of the gate rather than
deleted or left to fail every run:

```yaml
  - id: flaky-payment-redirect
    quarantined: true
    quarantine_reason: the sandbox gateway drops one redirect in twenty
    quarantine_until: 2026-09-15
```

It still runs, still reports, and still shows its verdict; only its power to
fail the gate is suspended. The report and every doctor line carry the reason
and the date inline, so the debt is visible rather than buried in a file nobody
opens.

Both companions are required, and a reason or a date without
`quarantined: true` is rejected outright, because it reads as a live quarantine
and is not one. `doctor` warns once the expiry is within a week and errors once
it has passed. Nothing has to be un-quarantined by hand: on the date the shield
lapses on its own and the case gates again.

## What the lane rejects

`ruby ~/.claude/cf/bin/change_config.rb doctor` reports each of these, and the
lane refuses to run past them, because every one of them means the gate checks
less than its author believes:

- a `suites` glob matching no readable file
- a suite file with no `suite:` id, or with no cases
- a `suite_version` above the installed one, or not a positive integer
- an unknown top-level or case key, or a key newer than the declared `suite_version`
- a `retries` above zero without `safe_rerun: true`
- a `timeout_ms` outside 1000..600000
- a duplicate case id within a suite
- a step naming an unknown verb, no verb, or more than one verb
- a case with no `acceptance`
- a quarantined case missing its `quarantine_reason` or its `quarantine_until`
- a `quarantine_reason` or `quarantine_until` without `quarantined: true`
- a `quarantine_until` that is not an ISO-8601 date
- a `lanes.testcases.gate_tags` entry no loaded case carries

## Example

```yaml
suite: checkout
suite_version: 2
cases:
  - id: guest-checkout-happy-path
    tags: [checkout, smoke]
    acceptance: >
      A guest can add an item and reach the confirmation page
      without creating an account.
    retries: 1
    safe_rerun: true
    steps:
      - goto: /products/widget
      - click: "[data-test=add-to-cart]"
      - expect_visible: "[data-test=cart-count]"
      - expect_text: { selector: "[data-test=cart-count]", equals: "1" }
      - goto: /checkout
      - fill: { selector: "#email", env: CHECKOUT_TEST_EMAIL }
      - click: "[data-test=place-order]"
      - expect_url: { contains: "/confirmation" }
```
