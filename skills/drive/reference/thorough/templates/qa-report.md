# {{title}} QA report

Writer: the workflow's ledger agent, and nobody else. Lane agents return
results; the main thread records owner approvals in run-log.md.

No connection strings, OTPs, passwords or secret values in this file. Real
accounts on a local data copy are named by role, never by address.

## Header

- Current tip: {{tip}}
- Counts (recomputed from the Findings rows): blocker 0, should-fix 0, nit 0
- Open blocking IDs: none
- Severity audit: not yet run

### Lane summary at the current tip

| Lane | Target | Result at tip | Blocking open | Nits new | Blocked flows |
| ---- | ------ | ------------- | ------------- | -------- | ------------- |

A lane with no run at this tip reads `carried from <sha>, needs owner approval
in run-log.md` until the main thread records an `OWNER APPROVAL` line there. It
never reads as passed on its own.

## Findings

| ID | Severity | Title | Role / viewport / theme | Repro | Expected vs actual | Confidence | Status |
| -- | -------- | ----- | ----------------------- | ----- | ------------------ | ---------- | ------ |

IDs are `QA-<lane>-<k>`. Status uses the same vocabulary as review-findings.md.

## Rounds

Oldest first. One subsection per round, then one per lane inside it:

### Round <n> (tip <sha>)

#### Lane <id> (<scope>; <target>)

Tip check, env re-read, server state.

| Flow | Role | Viewport | Theme | Result |
| ---- | ---- | -------- | ----- | ------ |

Blocked flows (reason; `needs owner` when the owner must decide):

Notes (writes made on shared data that later lanes should know; evidence paths
in the scratchpad; checked and dismissed):

## Pre-merge verification of fixes

One subsection per combined QA pass: the refs merged together, the throwaway
environment, flows run, findings as `FIX-<k>` in the Findings table.
