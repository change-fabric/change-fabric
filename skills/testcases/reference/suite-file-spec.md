# Test-case suite file specification

Suite version: 6

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
| 3 | `cases[].persona`, `cases[].safe_retry`. |
| 4 | Step verbs `wait_for_url`, `wait_for_text`, `wait_until_hidden`, `wait_for_response`, `wait_for_network_idle`. |
| 5 | Measured reads `rect.x`, `rect.y`, `rect.width`, `rect.height`, `rect.bottom`, `scroll_y`; the step verb `expect_stable`; the step options `label`, `budget_ms`, `budget_from`; and `tolerance` on `expect_equal`. |
| 6 | The step verbs `expect_relation` and `reference_get`; the read kind `list`; and `cases[].preconditions`. Adds the case statuses `warn` and `blocked_precondition`. |

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
| `cases[].persona` | string | no (default `default`) | Who the case runs as: a name under `lanes.testcases.personas` in CHANGE.md, `default` (the lane's `auth:` block, or no login when it has none), or `anonymous` (never logs in). A name the lane does not define fails the case and is a doctor error. See Sessions. | 3 |
| `cases[].safe_retry` | boolean | no (default false) | Says a mutating step (`click`, `fill`, `select`, `press`, `eval`) interrupted by an ended session may be replayed after the persona logs in again. Without it such a case fails `auth_interrupted`, because the action may already have taken effect server side. | 3 |
| `cases[].expects_logout` | boolean | no (default false) | Says the case ends its own session on purpose, such as a logout test that then asserts the login form. Its persona's `expired_when` probe and the re-login are off for it, so its post-logout steps run. | 3 |
| `cases[].quarantined` | boolean | no (default false) | Time-boxes this case out of the gate. It still runs and still reports; its failure just cannot fail the gate, and only until `quarantine_until`. Requires both companions below. | 1 |
| `cases[].quarantine_reason` | string | yes when quarantined | Why this case is quarantined, in plain English. Required, because without it nobody can tell a known flake from a real defect somebody muted. | 1 |
| `cases[].quarantine_until` | date (`YYYY-MM-DD`) | yes when quarantined | The day the quarantine ends. Quarantine is never permanent. The shield has already lapsed on this date, and the case gates again from then on with no second action from anybody. | 1 |
| `cases[].preconditions` | list of mapping | no | Steps run before the case's own, in the same page, with the same vocabulary. A failing precondition (a login check, a record that must exist) stops the case as `blocked_precondition`: not verified, which is neither a pass nor a failure. The case's steps do not run, and a precondition is never retried. In a suite_version 6 file a persona login that fails is a precondition failure too; older files keep failing the gate on a lost login. | 6 |
| `cases[].steps` | list of mapping | yes | The ordered steps. Each entry is a mapping naming exactly one verb below, plus an optional `timeout_ms`. The walk stops at the first failing step, because everything after it runs against a page that is no longer in the state the case described. | 1 |

## Step verbs

Compiled by `ChangeFlowCompiler` (`scripts/change_flow_compiler.rb`), which
owns this vocabulary; the list here is that compiler's, not a second copy of
it. Every verb takes either a scalar shorthand (`click: "#go"`) or a full
mapping (`click: { selector: "#go" }`). A `timeout_ms` may sit beside the
verb or inside its mapping (`wait_for: { selector: "#app", timeout_ms: 30000 }`);
the one beside the verb wins.

(suite_version 5) Any step may carry `label: name` (a word, unique in the
case). `budget_ms: N` on a step is a verdict, not a timeout: the step still
passes or fails on its own, and then fails with `span <from>..<step> took Xms,
budget Yms` when the span from the start of the step named by `budget_from`
(or from its own start) to its own end exceeds N. Put the budget on the wait
that confirms an action and point `budget_from` at the action's label, so the
span covers the click through the visible confirmation:

```yaml
- click: "button.save"
  label: save
- wait_for_text: { text: "Saved.", budget_ms: 1500, budget_from: save }
```

An unknown `budget_from`, or one naming a later step, is refused at compile
time. Every step records its `started_at_ms` and `duration_ms`; the case result
carries them as `step_durations`.

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
| action | capture | Reads a selector into a named variable: `{ selector, as: name, kind: text, number, or count }` (default `text`; `number` is the first number in the text, commas ignored). (suite_version 5) `kind` also takes `rect.x`, `rect.y`, `rect.width`, `rect.height`, `rect.bottom` (the element's `getBoundingClientRect()`, as numbers) and `scroll_y` (`window.scrollY`; with a `selector`, that element's `scrollTop`; the selector is optional only for `scroll_y`). (suite_version 6) `kind: list` reads the trimmed text of every element matching the selector, in document order, as a list for `expect_relation` `subset`. Each capture records its provenance: the page url at read time, the selector, the kind and `read_at`. `var` is accepted for `as`. |
| state wait | wait_for_url | (suite_version 4) Polls until the current url matches a glob (`wait_for_url: "/checkout/*"`, or `{ glob: }`) or a JavaScript regex (`{ regex: }`, checked when the step runs). In a glob `*` stays within a path segment, `**` crosses them and `?` is one character; a pattern starting with `/` matches the path and query, anything else the full url. |
| state wait | wait_for_text | (suite_version 4) Polls until the page text, or a `selector`'s text, contains `text` (`wait_for_text: Saved`, or `{ text:, selector: }`). |
| state wait | wait_until_hidden | (suite_version 4) Waits until the selector is absent or hidden, such as a spinner going away. |
| event wait | wait_for_response | (suite_version 4) Waits for a response whose url matches `url` (a glob, as `wait_for_url`) or `url_regex`, with an optional `status`. |
| event wait | wait_for_network_idle | (suite_version 4) Waits until no request has been in flight for `idle_ms` (100 to 10000, default 500; `wait_for_network_idle: true` takes the default). |
| assertion | expect_visible | The selector must be present and visible. |
| assertion | expect_hidden | The selector must be absent or hidden. |
| assertion | expect_text | The selector's text must `equals` or `contains` the expected string. |
| assertion | expect_url | The current url must `equals` or `contains` the expected string. |
| assertion | expect_status | The last navigation's HTTP status must equal the expected code, so a route that answers 500 with a rendered body is still a failure. |
| assertion | expect_count | The number of elements matching the selector must equal the expected count. |
| assertion | expect_equal | A captured `var` must equal a live read of `selector` (with `kind`) or a second captured `equals_var`. Compared as strings, so a captured number matches a count. A var no earlier step captures is refused at compile time. (suite_version 5) `tolerance: N` compares numerically within N instead; `kind: scroll_y` needs no selector. |
| assertion | expect_relation | (suite_version 6) `{ relation, reads, tolerance, settle }`: a relation between named reads. `equal` (`reads: { a, b }`, `abs(a - b) <= tolerance`), `le` (`a <= b + tolerance`), `sum` (`reads: { total, parts: [...] }`, the total equals the sum of the parts within `tolerance`) and `subset` (`reads: { a, b }`, every item of list `a` appears in list `b`, compared as trimmed text). A read is a captured variable name or a number; `tolerance` defaults to 0. `subset` takes only `list` reads and a `list` read belongs only to `subset`, both refused at compile time. Every `capture` and `reference_get` records its provenance (the page url at read time, the selector, the kind, and `read_at`), and the relation's reads carry it into the result. `settle: { reread: 1, freshness_selector }` re-reads each named read on a mismatch, in the order they were read: a page read goes back to its recorded url (skipped when already there), waits up to 2 s for the freshness selector's text to change, and reads its selector again with its kind; a `reference_get` read is fetched again with the same url and path and the same skew rule against its pair's new read (the pair is re-read first); literals are not re-read. A relation that matches on the re-read passes as a `warn` with `drift: true` and both value sets; one that still mismatches fails with both. Without `settle` a mismatch fails at once. |
| assertion | expect_stable | (suite_version 5) `{ var, selector, kind, tolerance_px, max_cls, wait }`: a figure must not move between first paint and the page settling. An init script installed before the first navigation records the selector's rect on the first animation frame it exists, samples it every frame it changes, and buffers layout-shift entries. The step waits for `document.fonts.ready` (`wait: fonts`, the default and only value) and for the network to be idle for 500 ms, counting requests already in flight (it fails if idle is never reached, and fails when nothing was recorded), then judges the whole window: the largest deviation of any sample from the first value must be within `tolerance_px` (default 0; `kind` default `rect.y`, and only `rect.*` kinds; the `selector` must be plain CSS, since the recorder resolves it in the page), so a header that moves 20 px during load and returns still fails. The layout-shift score attributed to the element (entries whose sources touched it, excluding those right after input) must be within `max_cls` (default 0). Both values ride on the step result with the entries. `var` keeps the final value. |
| action | reference_get | (suite_version 6) `{ var, url, json_path, pair, max_skew_ms }`: a figure fetched host-side from a reference API, kept in `var`, paired with the page read named by `pair`. `json_path` is `$` followed by `.key`, `['key']` and `[index]`; the value must be a number, a string or a list of those. Timing is "within `max_skew_ms` (default 2000) of the page read", not the same moment: both `read_at` times are recorded, and a reference outside the skew is read once more before the case is `blocked_precondition` ("reference skew"). The read is GET only, `https` (plain `http` only for a host listed `=http`), follows no redirect (a 3xx is an error), times out at 5 s, accepts at most 1 MiB, and must answer JSON. The host must be allowlisted by the invocation, not by the suite: `--reference-host <host>` (repeatable; `<host>=private,http` admits private addresses or plain http), until CHANGE.md carries the key. The name is resolved on the host and every address checked; private, loopback and link-local addresses (and their IPv6 forms) are refused unless the host is listed `private`, and the connection goes to the address that was checked, so a rebinding name is never trusted. A refused host, an unreachable reference or a skew that will not close blocks the case rather than failing it. The value is redacted with the lane's rules before it enters a report. |
| escape hatch | eval | Raw JS, run as-is in the page. Marked as raw in the compiled step and labeled as such in the report, so a reader can see exactly where the declarative contract was abandoned. Reach for it last. |

## Sessions

Each persona the selected cases use logs in once per run, in its own call. Its
cookies and the localStorage of the page the login ended on are seeded into
every case of that persona, each in its own fresh browser context. So the cases
of one persona share one server-side session: a case that logs out, switches
account or changes session state affects every later case of that persona.

A case notices its session has ended only when its persona declares
`expired_when` in CHANGE.md, and only by that declaration:

- `expired_when: { selector: "#signed-out" }`: an element present and visible
  only when logged out is visible after a step.
- `expired_when: { probe_url: /api/me, expect_status: 401 }`: a GET of that
  path, sent from the page with its cookies after a step, answers one of the
  listed statuses. A redirect matches any listed 3xx, such as 302 to the login.

The lane never guesses from the url, the login form or a 401 page. With no
`expired_when` there is no mid-case detection: a case whose session ended fails
like any other, and its finding suggests declaring `expired_when`.
When the probe fires, the persona logs in again exactly once, however many
cases noticed at the same time, and the case resumes with the new session,
inside the same attempt.
A fresh browser context has none of the page state the case built, so it
restarts at the last `goto` at or before the interrupted step (or at the first
step, on the page the login landed on) and replays from there. Only
navigations, waits, reads and assertions are replayed. If any replayed step is
`click`, `fill`, `select`, `press` or `eval`, the case fails `auth_interrupted`
instead, unless it sets `safe_retry: true`. A second session end in one attempt
fails the case.
A case that logs out on purpose sets `expects_logout: true`, which turns the
probe off for it so its post-logout assertions run.

A seeded case starts on the page the persona's login ended on, as it did when
each case logged in itself, unless its first step is a `goto`.

## State waits and event waits

A state wait checks the page as it is, repeatedly, until its condition holds or
its `timeout_ms` runs out, so it can sit anywhere in a case.

An event wait observes something that happens, and an event that already
happened cannot be observed. So an event wait attaches to the step before it
(`after: previous`, the default): its listener is armed before that triggering
step runs, and awaited after it, so a response that lands while the click is
still returning is still caught. Its `timeout_ms` and the idle window start
once the trigger has finished. `after: none` arms it when the wait itself
starts, and an event wait that is the first step, or follows another event
wait, arms the same way. Listeners are removed on a match, on the timeout, and
when the triggering step fails.

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

## Statuses and the gate

A case ends `pass`, `warn`, `blocked_precondition` or `fail` (and `skipped`, `auth_interrupted`, `partial_evidence`, the last two counting as failures). Severity is worst-of with the order pass, warn, blocked_precondition, fail; a run's status is its worst case. A `warn` passed every check but only after a re-read agreed with itself (drift); a `blocked_precondition` could not be verified, so it counts as neither passed nor failed and is listed under "Not verified" at the top of the report. Both pass the gate by default. `--fail-on-warn` makes a `warn` fail the gate and `--fail-on-blocked` does the same for a block; both are flags of the testcases lane (and so of `cf:qa --suite`), with no CHANGE.md key. In JUnit a warn case is a passing testcase carrying `cf.verdict=warn` and `cf.drift=true` properties, and a blocked case is `<skipped message="blocked_precondition: ...">`.

The report adds a "Not verified" section (first, when it has anything), a "Warnings" section listing each drift with its first and re-read values and times, a table of the captured figures (var, value, url, read time, freshness text, source: page or reference), and, per case, the reads and relations its verdict rests on. The case result carries the figures as `vars`, the relation checks as `relations`, and the history ledger stores both.

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
- two suite files declaring the same `suite` id
- a `persona` naming no persona in `lanes.testcases.personas`
- a step naming an unknown verb, no verb, or more than one verb
- a case with no `acceptance`
- an `expect_relation` naming a variable no earlier step captured, a `list` read outside `subset`, or a non-list read in `subset`
- a `reference_get` whose `pair` no earlier step captured
- a `preconditions` key that is not a non-empty list of steps
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
