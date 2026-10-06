# cf:resolve-threads reply reference

Read this before step 6 (replying to and resolving threads). It has no
bearing on steps 1-5.

## Verdicts

| Verdict | Bar | GitHub outcome |
|---|---|---|
| `fix` | The concern reproduces against the real code and the isolated trial fix holds | Applied on `repoPath`, committed, thread replied to and resolved |
| `wont_fix` | The concern does not hold up, is already covered, or costs more than it is worth | No code change; thread replied to with the rationale and resolved |
| `needs_human` | The right call depends on judgment this skill cannot make, or a `fix` diff conflicted once applied | No code change; thread replied to with the open question, left unresolved |
| in-run cluster | Recurring feedback whose root cause the Root cause phase fixed in one systemic commit | Every cluster thread replied to citing that one commit, and resolved |
| plan cluster | Recurring feedback whose honest fix is a redesign | Every cluster thread replied to with the deferral, left unresolved; cf:plan starts after the push, or a pointer is recorded instead when the run is nested or away mode is on |

## Reply style

One reply per thread, plain prose, no restating the original comment. State
the outcome first (fixed in commit X, not fixing because Y, or the open
question), then stop. Apply `cf:ai-slop`'s punctuation and tone rules to
every reply body before posting.

## Reply contracts

`scripts/thread_history.rb` reads these first sentences back from GitHub on
the next run, so they are exact, not stylistic:

- A fix (per thread or cluster) starts with `Fixed in <sha>.` where
  `<sha>` is at least 7 hex characters of the commit. An in-run cluster
  reply continues with the Root cause phase's one-sentence `reply`.
- A plan cluster reply starts with `Deferred to plan <slug>.` using the
  Workflow's `plan.slug`, then one sentence of root cause. A later run
  skips a thread whose last comment is this reply until a reviewer
  comments after it.
- A dismissal never starts with either phrase.
