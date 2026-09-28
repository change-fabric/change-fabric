# {{title}} owner handoff

Writer: the workflow's `handoff` segment agent, and nobody else. It rewrites
this file in full on every run and decides the verdict again from the ledgers
and run-log.md. To change the verdict, fix the cause (an owner approval goes in
run-log.md) and rerun `handoff`; never edit this file by hand.

## 1. Verdict

**READY | NOT READY at <tip>.** One bullet per failed precondition when NOT
READY, each naming what would clear it.

## 2. Status

| Item | Value |
| ---- | ----- |
| Tip | |
| Gate | |
| Review counts (from rows) | |
| QA counts (from rows) | |
| Lanes at tip / carried with owner approval | |
| Fixes merged | |
| Severity audit | |

## 3. What the plan got wrong

Numbered. Each item: what the plan said, what was true, and the corrected
command quoted in full.

### Commands to adjust before the remaining steps

## 4. Expected?

Data-dependent effects the owner rules on, each with a choice (for example
counts that change at deploy, drift against a mirror, QA judgment calls).

## 5. Owner final-pass checklist

Verbatim from the plan.

## 6. Diffs to read before merge

Computed from the paths actually changed, including every path each fix
touched. One command per line.

## 7. Follow-ups and filed issues

## 8. Copied from the plan

Present only when a deploy is in scope: the prod-day checklist and rollback,
verbatim.
