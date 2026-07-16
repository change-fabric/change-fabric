# pst:drive summary reference

Read this before composing any of the three bodies below. It has no bearing
on the rest of the workflow.

## Checkpoint 1 (step 8, before pushing)

At most 640 characters, plain prose. Cover, in order:

- What changed: the file or lane scope under review.
- What the iterate loop fixed: pull the counts and lane list from
  `fixesSummary`.
- Both thread-sweep outcomes: `fixed`/`wontFix`/`needsHuman` counts from the
  step-2 and step-6b `pst:resolve-threads` runs, folded into
  `execSummaryDraft`'s `{{threadSweeps}}` placeholder.
- The local CI prediction result (`ciPrediction.green` and any job that did
  not pass).

No filler, no praise, no restating the diff line by line, no AI-slop
glyphs. State the verdict, not an argument for it.

## Checkpoint 2 (step 10, before approving)

At most 640 characters, plain prose. Cover, in order:

- The final diff state: what actually landed after any CI-triggered
  re-push (step 9), if one happened.
- The real CI result from GitHub's own check-runs, not the local
  prediction: which jobs ran, that they are green.

Shorter than checkpoint 1 is fine; there is less new information at this
point. Same rules: no filler, no praise, no AI-slop glyphs.

## Approval review body (step 11)

Plain prose GitHub PR review body for the `event: "APPROVE"` call. State
concretely what was verified, not how good the change is:

- Which quality lanes ran (`selectedSkills`) and that the iterate loop
  reached a would-approve state (`converged`).
- That real CI is green, naming the check-runs if the review body has
  room.
- That both thread sweeps left no open threads (or, if `needsHuman`
  entries remain, say so plainly rather than approving over them silently;
  a `needsHuman` thread from either sweep is only compatible with an
  approval when the checkpoint summaries already surfaced it as a known,
  accepted gap).

No praise, no generic enthusiasm, no AI-slop glyphs, no agent attribution
footer.
