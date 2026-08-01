# cf:sweep summary reference

Read this before composing any of the four outputs below. It has no bearing on
the rest of the workflow.

## Sweep summary (step 5, every mode)

The main output of a one-off run and the per-tick output of a loop run. Lead
with the headline, at most 640 characters, from the Workflow's `reportDraft`,
then the sections below. Skip any section that has nothing in it rather than
printing an empty heading.

1. **Order.** One line per PR in `plan` order: position, `#number`, author,
   trust level, action, and the one-line rationale. Name the branch only when
   the action is `rebase_then_merge` and the rationale needs it.
2. **Conflicts.** Only the pairs where `conflicts` is true: the two PR numbers,
   the conflicted files, and the mitigation. A clean overlapping pair is worth
   one summary line ("N overlapping pairs merged clean"), not a list.
3. **Infra and migration gates.** Each gate's kind, what it applies to, and the
   `manualStep` verbatim. This is the section a human acts on; do not compress
   a `terraform apply` step into a verb.
4. **Holds.** Every entry in `holds` with its `blockedReasons`, so it is
   obvious what would make it eligible next tick.
5. **Author warnings.** Any `warnAuthor` text, and whether it was posted to the
   PR or is being reported for a human to send.

State the plan, not an argument for it. No praise, no restating each diff, no
AI-slop glyphs.

## Landing checkpoint (step 6, Land with sign-off only)

At most 640 characters, plain prose, asked once for the whole queue rather than
once per PR. Cover, in order: how many PRs are queued and in what order, the
gates that must be satisfied by hand first, anything held and why, and what the
run will do next (drive each queued PR through `cf:drive`, then merge in
order). One go/no-go for the sequence.

## Per-PR merge note (step 7)

When a PR merges as part of a sweep, its merge is otherwise indistinguishable
from a hand merge, so say what the sweep knew: one line naming its position in
the sweep order and any PR it was sequenced ahead of or behind. Only worth
posting when the order was non-obvious (a conflict mitigation, an infra gate, a
stacked branch).

## Author warning comment

Posted to a PR whose author is about to lose time. Plain, specific, and short:
what is landing ahead of them, which files collide, and what to do (rebase on
`<trunk>` after `#N` merges). No apology, no praise, no AI-slop glyphs, no
agent attribution footer.
