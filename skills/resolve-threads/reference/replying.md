# cf:resolve-threads reply reference

Read this before step 6 (replying to and resolving threads). It has no
bearing on steps 1-5.

## Verdicts

| Verdict | Bar | GitHub outcome |
|---|---|---|
| `fix` | The concern reproduces against the real code and the isolated trial fix holds | Applied on `repoPath`, committed, thread replied to and resolved |
| `wont_fix` | The concern does not hold up, is already covered, or costs more than it is worth | No code change; thread replied to with the rationale and resolved |
| `needs_human` | The right call depends on judgment this skill cannot make, or a `fix` diff conflicted once applied | No code change; thread replied to with the open question, left unresolved |

## Reply style

One reply per thread, plain prose, no restating the original comment. State
the outcome first (fixed in commit X, not fixing because Y, or the open
question), then stop. Apply `cf:ai-slop`'s punctuation and tone rules to
every reply body before posting.
