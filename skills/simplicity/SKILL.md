---
name: cf:simplicity
group: rubrics
description: Anti-over-engineering rubric. A cf:roast lens only (--lens cf:simplicity), loaded by cf:plan step 7b and the cf:drive simplicity lane; never auto-applied.
---

# Simplicity

A lens for cf:roast (`--lens cf:simplicity`) on a plan, an architecture doc, or a diff. It has no `auto:` block on purpose, so it never joins the per-change review. It advises; it never blocks a push or a plan handoff.

## The question

What is the least code, the fewest files, and the fewest dependencies that meet the stated purpose? Judge the input against its own stated goal, not against a bigger product it might become.

## Smells

- Speculative generality: hooks, parameters, or extension points for a case nobody has asked for.
- A single-implementation interface, base class, factory, or registry.
- Config or options nobody sets, or that only ever take their default.
- A new dependency where the standard library or code already in the repo serves.
- Scope beyond the stated goal: features, flags, or refactors the purpose does not need.
- Pass-through or middle-man layers that forward calls without adding a rule.
- Plan phases or components with no requirement behind them.

## Each finding must

1. Name the requirement the complexity serves, or say `none`.
2. Give a concrete simpler alternative: what to delete, inline, or replace, and with what.
3. Estimate the saving (lines, files, deps removed if the fix is applied) at the end of the issue's `fix` field (the roast schema has no separate field for it), for example `Saves about 40 lines and one file.`. An estimate is never a measurement.

## Marking

Begin each simplicity finding's `problem` with `cf:simplicity:`. `simplicity_signals.rb verdict` counts only findings carrying that prefix (or a non-null `saving`), so other issues in the same round never move the verdict.

## Priority

The verdict follows mechanically from the accepted findings: any accepted P0 means rethink, else any accepted P1 means trim, else ship.

- P0: the shape is wrong. The design needs rethinking, not trimming (rethink).
- P1: removable complexity with a clear, simpler alternative (trim).
- P2: taste. Worth a note, never worth a verdict.

## Exemptions

Complexity is necessary, and not a finding, when the text or repo shows evidence of one of these:

- a test seam the tests actually use;
- a second caller already planned in the same plan or present in the repo;
- a security or compliance boundary;
- a published API contract.

An exemption claimed without evidence does not count. In a plan, a settled decision in a `## Decisions` section counts as a grounded rebuttal: do not re-litigate it, though a finding may still note its cost.

## Signals

`simplicity_signals.rb` may supply a signals JSON (new files, new types per 100 lines, added dependencies, unused definitions, single-implementation bases). A signal is a hint, never a finding by itself: confirm it in the input before raising it. The Ruby unused-method signal is noisy on `send`, callbacks, and DSLs; discount it there.

## Example (synthetic)

Before, a factory with one product:

```ruby
class NotifierFactory
  def self.build(kind) = { email: EmailNotifier }.fetch(kind).new
end

class EmailNotifier
  def deliver(user, text) = Mailer.send_mail(to: user.email, body: text)
end

NotifierFactory.build(:email).deliver(user, "Welcome")
```

Finding (P1, trim): requirement served: none, only email exists. Simpler: drop the factory and call one method. Saving: about 4 lines, 1 file, 0 deps.

After:

```ruby
def notify(user, text) = Mailer.send_mail(to: user.email, body: text)

notify(user, "Welcome")
```
