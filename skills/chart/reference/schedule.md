# Schedule

Durations on a scaled time axis, gantt-like. Follow `grammar.md` for everything not stated here.

## When to use

- Phases, tasks or rollout stages with a start and an end, where length and overlap are the point.

## When not to

- Events in order without durations, or milestones whose spacing does not matter: that is cf:diagram's `timeline`.
- Dependencies between tasks as the main message: draw a cf:diagram `flow`.

## Rules

- `tasks: [{ "name", "start", "end" }]`, one row each, top to bottom in spec order.
- Start and end are ISO dates (`2026-11-02`) or plain numbers (week 3, sprint 5); do not mix the two.
- With dates, ticks step in whole days and read like `Nov 5`; set `x.unit` to `day`.
- The time axis needs a label and unit [axis-label] and 3 to 8 ticks [tick-count].
