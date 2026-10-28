---
name: cf:usability
group: rubrics
description: Nielsen's ten usability heuristics (1994) as an inspection rubric. Auto-applied by the cf shim on every UI change (markup, styles, components, templates, DESIGN.md, walkthrough storyboards); also invocable directly and loaded by name by cf:prototyping, cf:design, cf:prototype, and cf:walkthrough.
auto:
  extensions: [html, htm, css, scss, jsx, tsx, vue, svelte, erb]
  paths:
    - "DESIGN.md"
    - "**/DESIGN.md"
    - "walkthrough/*/storyboard.json"
---

# Nielsen Usability Heuristics

Source: Jakob Nielsen, ten usability heuristics (1994), https://www.nngroup.com/articles/ten-usability-heuristics/

Rule: heuristics yield hypotheses, not verdicts. Rate each issue on severity 0 to 4 (0 not a problem, 1 cosmetic, 2 minor, 3 major, 4 blocks the task) and fix the highest first.

| Heuristic | Observable check (screen or recorded sequence) | Default fix |
|---|---|---|
| H1 Visibility of system status | Every action shows a result: a spinner, toast, count change, or new state | Add feedback within the same scene |
| H2 Match between system and the real world | On-screen words are the PRD's and the user's, not internal or schema names | Rename to the domain term |
| H3 User control and freedom | Back, cancel, or undo is visible wherever a step can be left | Add an exit or undo next to the action |
| H4 Consistency and standards | The same control looks and behaves the same across screens and scenes | Reuse one component and label |
| H5 Error prevention | A destructive or costly action asks for confirmation or is reversible | Add a confirm step or soft delete |
| H6 Recognition rather than recall | Options, recent items, and prior inputs are shown, not remembered | Show choices and defaults in place |
| H7 Flexibility and efficiency of use | A faster path exists for repeat users (shortcut, bulk action, saved view) | Add an accelerator without hiding the basic path |
| H8 Aesthetic and minimalist design | Each screen has one primary action and no competing noise | Demote or remove secondary content |
| H9 Help users recognize, diagnose, and recover from errors | Error states say what went wrong in plain words and how to fix it | Rewrite the message with a next step |
| H10 Help and documentation | Help or guidance is reachable from the place it is needed | Add inline hint or a help link |

Favor:
- Checking the recorded sequence, not only single stills.
- Naming the heuristic, the screen, and the evidence for each issue.
- The smallest change that removes the issue.

Avoid:
- Treating a heuristic as a pass/fail law without user evidence.
- Copying NN/g definitions or posters into a repo; link instead.
- Bundling unrelated redesign into a usability fix.

Output, one line per heuristic: `H<n> pass`, `H<n> issue (severity <0-4>): <evidence>`, or `H<n> not evaluable: <why>`.
