# cf:drive summary reference

Read this before composing any of the three bodies below. It has no bearing
on the rest of the workflow.

## Checkpoint 1 (step 8, before pushing; only under `--signoff`)

At most 640 characters, plain prose. Cover, in order:

- What changed: the file or lane scope under review.
- What the iterate loop fixed: pull the counts and lane list from
  `fixesSummary`.
- Both thread-sweep outcomes: `fixed`/`wontFix`/`needsHuman` counts from the
  step-2 and step-6b `cf:resolve-threads` runs, folded into
  `execSummaryDraft`'s `{{threadSweeps}}` placeholder.
- The local CI prediction result (`ciPrediction.green` and any job that did
  not pass).

No filler, no praise, no restating the diff line by line, no AI-slop
glyphs. State the verdict, not an argument for it.

Under `--signoff`, the step-2b recurrence stop uses this format too, with
the recurrence (plan slug, cluster threads) in place of the loop results.

## Checkpoint 2 (step 10, before approving; only under `--signoff`)

At most 640 characters, plain prose. Cover, in order:

- The final diff state: what actually landed after any CI-triggered
  re-push (step 9), if one happened.
- The real CI result from GitHub's own check-runs, not the local
  prediction: which jobs ran, that they are green.

Shorter than checkpoint 1 is fine; there is less new information at this
point. Same rules: no filler, no praise, no AI-slop glyphs.

## Approval review body (step 11)

This body is only ever composed once the step-8 gate [DR-1] has already
passed, so a `needsHuman` or `conflicts` thread cannot still be open at
this point; never word the body as if it might be overriding one. Plain
prose GitHub PR review body for the `event: "APPROVE"` call. State
concretely what was verified, not how good the change is:

- Which quality lanes ran (`selectedSkills`) and that the iterate loop
  reached a would-approve state (`converged`).
- That real CI is green, naming the check-runs if the review body has
  room. When `ciPrediction.noCi` is true, state plainly: "No CI configured
  for this repo."
- That both thread sweeps left no open threads.

No praise, no generic enthusiasm, no AI-slop glyphs, no agent attribution
footer.
