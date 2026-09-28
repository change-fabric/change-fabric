# {{title}} run log

Writer: the main thread, and nobody else. Agents read it; none write it.

The record of what actually happened, in order: tips, main-thread-only steps,
owner rulings and approvals, and every divergence from plan.md. The handoff
agent builds "What the plan got wrong" from it and checks approvals against it,
so write rulings in the exact line formats below.

## Tips

`- <date> <segment>: <ref> = <sha>`

## Divergences from plan.md

Numbered. What the plan said, what was true, what changed (including any
engine patch to workflow.js and why).

## Owner rulings

`- RULING <date>: <ID or topic>: <decision, verbatim where possible>`

## Owner approvals

One line per approval. A lane result carried to a newer tip needs its own line;
without it the handoff reads NOT READY.

`- OWNER APPROVAL <date>: carry lane <id> from <sha> to <tip>; <why the diff between them does not touch it>`
`- OWNER APPROVAL <date>: merge <ref>`

## Main-thread steps

One subsection per step the plan reserves for the main thread (database
operations, merges, rehearsal, prod), with the commands run and their counts.
Never a connection string or secret.
