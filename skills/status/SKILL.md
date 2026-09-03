---
name: cf:status
description: Arms a recurring self-status ping on a real cron loop and prints a red/yellow/green progress line per active work item on each tick. Takes the interval as an argument or asks for it, refreshes a session-scoped status store every tick, prints only when something changed, and stops itself once every item reads green.
---

# CF Status

Report this session's own progress on a fixed interval, one line per active
work item, so the human can glance at the terminal and see where the work
stands without asking.

Trigger: `/cf:status [<minutes>]` to arm, `/cf:status tick` on every fire.

`/cf:status 10` arms a ten-minute ping immediately. A bare `/cf:status` asks
for the interval first. `/cf:status tick` is not typed by a human: it is the
exact prompt string the cron re-injects into this session on every fire.

## Modes

Branch on the positional argument before doing anything else.

| Invocation | Mode | What it does |
|---|---|---|
| `/cf:status tick` | Tick | Recompute the list, diff it, print or collapse, auto-stop if all green. Never calls `CronCreate`. |
| `/cf:status <N>` | Arm | Arm at N minutes with no question. |
| `/cf:status` | Arm | Ask for the interval, then arm. |

The literal string `tick` is the only tick trigger. A tick prompt of bare
`/cf:status` would re-enter the arm path and create a second cron job on every
fire, so the prompt handed to `CronCreate` must be exactly `/cf:status tick`.

## Arm mode

1. **Interval.** If the argument is a positive integer, that is the interval
   in minutes; ask nothing. Otherwise read the away store for this session
   (`~/.claude/cf/sessions/<session_id>/away`, the file `cf:away` writes). If
   away mode is on, arm at **10 minutes** and say so in the confirmation as an
   assumption taken; do not call `AskUserQuestion` (`away_guard.rb` denies it
   anyway). If away mode is off, one `AskUserQuestion` call, header
   `Interval`, four options in this order:

   - **10 minutes**, description "Recommended: frequent enough to be useful,
     quiet enough to stay out of the way."
   - **5 minutes**, for a short push where the state moves fast.
   - **15 minutes**, for longer-running work.
   - **30 minutes**, for a background job checked occasionally.

2. **Session id.** Run
   `ruby ~/.claude/cf/bin/status_store.rb resolve` and use the id it prints
   for every later call in this session, passing it explicitly as
   `--session <id>`. If it prints null, say so and stop: without a session id
   there is nowhere to persist state, and an unpersisted loop cannot diff or
   auto-stop. The id must be this session's own identity and no other:
   `resolve` reads `CLAUDE_CODE_SESSION_ID` and has no cross-session fallback
   on purpose, so two sessions running side by side on one machine can never
   share a store and delete each other's cron.

3. **Create the cron.** Call `CronCreate` with the prompt exactly
   `/cf:status tick` and the schedule for the chosen interval (N minutes with
   N at most 59 maps to `*/N * * * *`). Keep the job id it returns.

4. **Seed the store.**
   `ruby ~/.claude/cf/bin/status_store.rb arm --session <id> --interval <N> --cron <job_id>`
   then write the opening item list with one `write` call (step 2 of Tick
   mode describes how the list is built). The first list is printed in full;
   there is nothing to diff against.

5. **Confirm** in at most three lines: the interval, the job id, the number of
   items seeded, and how to stop early (`CronDelete` on that job id). If the
   interval was defaulted under away mode, say that here.

## Tick mode

Every tick is a full recompute, not a resumption. Nothing is cached between
ticks except what is in the store.

1. **Resolve** the session id the same way arm mode did, then run
   `ruby ~/.claude/cf/bin/status_store.rb show --session <id>` and check
   `armed`. If it is false, the ping was disarmed (or never armed) but the
   cron survived: print one line saying the ping is no longer armed, call
   `CronDelete` on this job if the id can be determined some other way, and
   stop. Do not call `write` first and do not re-arm from inside a tick: a
   `write` against an unarmed session silently creates a partial store
   entry (`armed: true` but `cron_job_id: null`), which is exactly the state
   this check exists to avoid.
2. **Recompute the list from live context**, not from the store: read this
   session's actual state (the current todo list, what the last few turns
   were doing, what is blocked waiting on a human or an external system) and
   express it as one item per active work item, each a short imperative or
   present-tense phrase and a percent. Keep the list short; if it runs past
   about eight items the list has stopped being glanceable and should be
   collapsed to the items actually in flight. Percent is a judgment call
   about how much of that item is done, and it must sit in the band that
   matches its real state (see Bands).
3. **Write and diff in one call:**
   `ruby ~/.claude/cf/bin/status_store.rb write --session <id> --item "10:Blocked on API keys" --item "55:Writing plan.md"`
   The response carries `changed`, `all_green`, `rendered`, and
   `cron_job_id`.
4. **Print.** If `changed` is true, print the `rendered` lines verbatim, one
   per line, nothing else: no preamble, no summary, no closing sentence. If
   `changed` is false, print exactly one line, `No change since HH:MM`, using
   the `last_tick` timestamp from the previous state in local time.
5. **Auto-stop.** If `all_green` is true, call `CronDelete` with the
   `cron_job_id` from the write response, then
   `ruby ~/.claude/cf/bin/status_store.rb disarm --session <id>`, and print
   one final line saying the loop is done and the ping has stopped. Do not
   arm anything further.

## Bands

| Emoji | Band | Meaning |
|---|---|---|
| 🔴 | 0-33% | Not started, or blocked on something outside this session. |
| 🟡 | 34-79% | In progress. |
| 🟢 | 80-100% | Done, or near enough that nothing is expected to go wrong. |

Line format, exactly: `<emoji> <label> (<NN>%)`.

The bands are enforced in `status_store.rb`, which derives the emoji from the
percent. Never hand-write an emoji into a line; give the store a percent and
print what it renders. That is what keeps the colour and the number from
contradicting each other.

**This palette is deliberately not the severity palette.**
`scripts/render_finding_comment.rb` uses red/orange/green for code-review
severity (red for P0-P1, orange for P2, green for a clean result). That is a
different vocabulary for a different question. This one is workflow progress:
red is not-started-or-blocked, yellow is in-progress, green is done. The two
are not meant to be reconciled, and this skill must not be "fixed" to reuse
the severity set.

## Stopping

Auto-stop at all-green is the normal end. To stop earlier, call `CronDelete`
on the job id from the arm confirmation (or from
`ruby ~/.claude/cf/bin/status_store.rb show --session <id>`), then
`status_store.rb disarm --session <id>`. Deleting the cron without disarming
leaves a stale store that the next arm overwrites anyway; disarming without
deleting the cron leaves the loop firing into an unarmed store, which reports
an empty list every tick. Do both.

## Caveats

- A tick that fires while a turn is running is queued, not injected: it waits
  for the turn to end. During a long turn the printed list can therefore be a
  few minutes older than the interval implies.
- The list is the agent's own judgment about its own work. It is a progress
  report, not a measurement, and a percent is an estimate.

## Failure modes

- No session id resolves. Say so and stop: nothing is armed, nothing is
  written, and no cron is created.
- `CronCreate` or `CronDelete` is not reachable in this session context. Arm
  mode says so and stops rather than pretending it armed. A `CronDelete` that
  fails at auto-stop is different: print the all-done line anyway, say the
  cron could not be deleted, and give the job id so a human can delete it.
- A tick reports `armed: false` from `show`. Print one line saying the ping is
  no longer armed, call `CronDelete` on the job id if it can be determined,
  and stop: do not re-arm from inside a tick.
- The chosen interval does not divide 60 evenly. Pass it through anyway; if
  the harness reports a rounded schedule, repeat the rounded value in the arm
  confirmation rather than the requested one.
