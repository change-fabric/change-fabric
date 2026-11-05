# Record template

Written to `docs/creative/NNNN-<slug>.md` in the target repo. Self-contained: a reader with no access to the working directory must understand the decision. No images are committed; describe moodboards in words.

```
---
status: accepted            # proposed | accepted | superseded by NNNN
date: YYYY-MM-DD
applies_to: [ui, brand]     # consumers filter on this; without ui, cf:design touches only brand rules
working_dir: ~/.claude/cf/imagine/<area>/<slug>   # tilde, informational
options: 3
rounds: 2
design_md: none             # none | promote
design_md_reason: <one line>
---
# NNNN - <Decision as a sentence>
## Status
## Context
## Options considered
## Decision
## Rejected
## Production plan
## Consequences
## Open questions        (only when away mode or unresolved)
## Handoff
```

Guidance per heading:

- Status: the status word and, when superseded, the number that replaced it.
- Context: the it, the audience, the constraints, and the inputs read, in a short paragraph.
- Options considered: one paragraph per option, including its name and what it is NOT.
- Decision: the chosen direction. Attribute each pick to its source option. Say what the critic rounds changed.
- Rejected: why each rejected option or element lost, in one line each.
- Production plan: the buildable plan, covering palette, type, voice, imagery, motion, and format as applicable. Tag every line `[evidence]`, `[assumption]`, or `[proposal]`.
- Consequences: what becomes easier, what becomes harder, and what to revisit.
- Open questions: contested calls left open, each with the options and the recommended default. Omit the heading when there are none.
- Handoff: with `design_md: none`, the line "no DESIGN.md change". With `design_md: promote`, the exact command, for example `cf:design docs/creative/NNNN-<slug>.md`.
