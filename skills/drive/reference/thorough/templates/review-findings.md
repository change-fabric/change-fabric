# {{title}} review findings

Writer: the workflow's ledger agent, and nobody else. Segment agents return
results; the main thread records rulings in run-log.md. Neither edits this file.

No connection strings, OTPs, passwords or secret values in this file.

## Header

- Range: {{base}} ({{base_sha}}) .. {{head}} (tip reviewed: {{tip}})
- Counts (recomputed from the rows below): blocker 0, should-fix 0, nit 0
- Open blocking IDs: none
- Severity audit: not yet run

### Range commands per unit

| Unit | Title | Range reviewed |
| ---- | ----- | -------------- |

## Findings

One table. Severity is a column, so a reclassification edits one cell and the
row stays put. IDs are `<unit>-<k>` from review and `FIX-<k>` from fix
verification.

| ID | Severity | Title | File:line | Scenario | Suggestion | Confidence | Status |
| -- | -------- | ----- | --------- | -------- | ---------- | ---------- | ------ |

Status is one of: `open`, `fixing <ref>`, `fixed <ref>`,
`wontfix <owner-approved reason>`, `deferred <issue>`.

## Merged and dropped

Duplicates merged across units, and findings dropped as known-deferred.

## Coverage

One subsection per unit: what was read, what was verified clean, what could
not be read. A unit that returned nothing is named here and must be rerun.

## Fix verification

One row per verification pass, oldest first.

| Ref | Branch | Round | Range reviewed | Verdicts | New findings |
| --- | ------ | ----- | -------------- | -------- | ------------ |

## Severity audit

Owner rulings applied from run-log.md, one line each:
`<ID>: <from> -> <to>, <reason> (run-log.md, <date>)`.
