# Delivery protocols

The wire contracts behind the progressive-delivery keys (`change_config.delivery`
and `change_policy.delivery`, spec 0.24.0). cf supplies the contract and the
validators; the consumer's own app worker runs the controller and the flags
adapter. cf never calls a production flags CLI with production credentials. The
gates rest on hooks, not on token scope: an admin token can bypass them, and
that limit is documented, not closed.

Code: `scripts/change_flags_protocol.rb`, `scripts/change_flags_fixture.rb`,
`scripts/change_verdict.rb`, `scripts/change_delivery.rb`.

## Two version counters, never mixed

- `rollout_revision`: the integer in the per-flag file (or inline rollout). A
  verdict is actionable only when its `rollout_revision` equals the current one
  exactly; lower or higher is ignored and logged.
- `flag_state_version`: the flags adapter's own compare-and-swap counter,
  returned on every reply. The request field `expected_revision` always means
  this, never `rollout_revision`.

## cf.flags/1

One JSON request on stdin, one JSON reply on stdout.

Request: `{protocol: "cf.flags/1", request_id, idempotency_key, op, flag, env,
expected_revision, cohort?, fencing_token?, recovery_auth?}` with `op` one of
`get`, `set_cohort`, `disable`, `enable`. `expected_revision` is required on a
write. `cohort` is required for `set_cohort`.

Reply: `{protocol, request_id, ok, flag, env, state: {enabled, cohorts,
incident: open|closed, incident_id?}, flag_state_version, error?: {code,
message}}`. Error codes: `revision_conflict`, `incident_open`, `fenced`,
`unknown_flag`, `unavailable`, `invalid_request`.

Rules every adapter must obey (the reference state machine is
`ChangeFlagsProtocol.apply`, and the conformance traces and the fixture adapter
agree with it):

- A write whose `expected_revision` does not match returns `revision_conflict`
  and changes nothing.
- `disable` always applies. With a stale revision it still disables and sets the
  incident latch, and the reply is `ok: true` carrying the `revision_conflict`
  error. It also ignores fencing, so a superseded controller can still turn a
  flag off.
- A breach, or a disable from any source, sets a durable `incident: open`
  latch. While open, `enable` and `set_cohort` fail with `incident_open` unless
  they carry a `recovery_auth`.
- `recovery_auth`: `{incident_id, rollout_revision, fix_commit, cohort:
  "internal", fencing_token, nonce, signature}`. Bound to the open incident, the
  `internal` cohort and the request's fencing token; single use (the nonce is
  burned); a new breach opens a new incident, which kills any earlier one's
  auth. Signature verification is the worker's job; the protocol checks the
  binding. A successful recovery closes the incident.
- A write carrying a `fencing_token` below the current lease fails with
  `fenced`.
- The same `idempotency_key` returns the first reply and applies nothing again.

### Disable as an operation

Disable is attempted first, idempotently, with retries for up to 120 seconds (a hard bound: each call gets only the time left, and expiry reports a timeout),
then confirmed by a `get` that reads the off state
(`ChangeFlagsProtocol.disable_confirmed`). Timeout, outage, an ambiguous
outcome or an unconfirmed off state is `disable_unconfirmed`: page at once and
halt automatic recovery. Provider propagation lag is real; the consumer keeps
an app-side kill switch.

### The fixture adapter

`kind: fixture` keeps state in a JSON file (`path`, default a temp file) and
honors every rule above. It is what tests and dogfood dry runs use.

```
ruby scripts/change_delivery.rb flags new-checkout get              # CHANGE.md from the base branch
ruby scripts/change_delivery.rb flags new-checkout enable --config CHANGE.md   # local dry run, working tree
ruby scripts/change_delivery.rb flags new-checkout set_cohort --cohort internal --expected-revision 1
```

`flags` reads the wiring from CHANGE.md on the base branch (the destination's default branch, via `ChangePolicy::Source`), so a branch cannot repoint the adapter it is judged by; `--config` reads the working tree and is labelled a local dry run. A command adapter's reply is validated against cf.flags/1 (and must answer the same request); a malformed reply is a failure, never `ok`. A `kind: command` adapter is the consumer's own CLI; cf reaches it only for
staging and dry runs.

## cf.verdict/1

Written by the consumer controller, validated by cf, read by the triage
watcher.

`{protocol: "cf.verdict/1", rollout, flag, rollout_revision, rollout_digest,
stage, stage_entry_id, cohort, controller_id, fencing_token, seq, verdict:
pass|breach|unknown, coverage: complete|incomplete, guards: [{name, observed,
limit, ok}], telemetry_at, evaluated_at}`.

- A `pass` with `coverage: incomplete`, with telemetry older than
  `max_telemetry_age_s` (180) at evaluation, or with a failed guard is rejected.
  It must read `unknown`. `unknown` never advances a stage.
- Each stage entry has a `stage_entry_id`; each controller lease a monotonic
  `fencing_token`; each verdict a monotonic `seq`. Advancement accepts evidence
  only for the current stage entry and rejects out-of-order `seq`, an
  `evaluated_at` more than 60 seconds in the future, and tokens below the
  current lease (`ChangeVerdict::Gate`). A triage re-enable starts a new stage
  entry, so pre-breach passes are never reused.

`cf.heartbeat/1`: `{protocol, controller_id, fencing_token, rollout,
rollout_revision, at}`. A gap over `heartbeat_max_gap_minutes` (10) alerts.

```
ruby scripts/change_delivery.rb validate-verdict test/fixtures/delivery/verdict_pass.json
```

## Controller semantics and the conformance suite

Normative for any consumer controller:

- A "new" 5xx or exception is an error fingerprint on flagged spans in the
  evaluation window (default 5 minutes) not seen on flag-off spans in the
  baseline window.
- The p95 guard needs at least 50 baseline requests in `flag_off_last_7d`;
  below that it reads `unknown`.
- `min_requests` and `dwell_minutes` count from the stage entry. An `unknown`
  evaluation pauses the dwell clock, and dwell never completes while the last
  verdict is `unknown`.
- Zero traffic in a window gives `unknown`, never `pass`.
- Error guards need complete error capture for flagged traffic from an
  unsampled source (`metrics.<name>.error_source: unsampled`). Without proof of
  coverage (a sampled source, or span drop counters above zero) the verdict
  carries `coverage: incomplete` and reads `unknown`.
- Only guards the rollout configures are enforced, and pacing defaults to `manual` when omitted.
- At `everyone`, guards keep running for 7 days after entry; then the rollout is
  `complete`. Entering `everyone`, and every transition of a money-affecting or
  `advance: manual` stage, waits for a human approval.

`test/fixtures/delivery/traces/*.json` are the conformance traces: a trace is
`{name, description, policy, rollout: {stages, pacing, guards}, steps, expect}`.
Each step carries pre-computed observations (`requests`, `new_5xx`,
`new_exceptions`, `p95_ratio`, `baseline_requests`, `coverage`,
`telemetry_age_s`, `approval?`) at `at_s` seconds from the start of the trace. A
controller reads the trace without `expect` on stdin and prints
`{"transitions": [{step, verdict, action, stage}]}`, with `action` one of
`hold`, `advance`, `await_approval`, `disable`, `halted`, `complete`.

```
ruby scripts/change_delivery.rb conformance -- <controller argv>
ruby scripts/change_delivery.rb conformance -- ruby scripts/change_delivery_reference.rb
```

`scripts/change_delivery_reference.rb` is a small worked controller that passes
every trace. Exit 0 only when every trace matches.
