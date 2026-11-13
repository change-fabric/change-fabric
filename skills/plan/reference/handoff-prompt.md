Fill every `{{placeholder}}` from this run, then print the fenced block below
as the final message. Do not add commentary inside the fence.

Every path placeholder here (`{{plan_path}}`, `{{goal_path}}`,
`{{workflow_path}}`, `{{repo_path}}`) takes the tilde form (from
`plan_paths.rb`'s `_tilde` fields or its `tildeize` verb), never the literal
absolute path: this block is meant to be pasted into a fresh session, possibly
on another machine, and a literal `/Users/pxt/...` or `/home/exe/...` breaks
the moment the same account's home sits under a different literal path there.

`{{judged_note}}` is empty unless the ledger has `Answered by: judge`
entries. Then it reads: "Judged decisions (unreviewed): the plan's
`### Judged decisions (unreviewed)` subsection lists answers an LLM judge
gave, not the user. They are open to revisiting; flag any you would answer
differently before running the phases they touch."

`{{visuals_note}}` is empty when the plan has no visuals (its `## Visuals`
section reads "None"). Otherwise it reads: "Visuals in diagrams/ are
illustrative; plan.md wins on any conflict. Roast score and any open P0/P1
are in plan.md's ## Roast section."

`{{stack_note}}` is empty when the plan has one PR phase or none. When the
plan has more than one PR phase, it reads, with `{{plan_dir}}` in tilde form:
"When the phases are open as PRs, run `/cf:sweep stack {{plan_dir}}`." It is
the last line of the block, so the stack lands one PR at a time by default.

```markdown
Execute the plan at {{plan_path}}.

Read these three files first, in this order:

1. {{goal_path}} - what done looks like and why it matters. Short by design.
2. {{plan_path}} - the full technical plan. This is the source of truth for
   what to build. Its "Decisions (settled, do not re-litigate)" section
   records answers the user already gave during planning. Those are fixed.
   Do not reopen them, do not offer alternatives they already rejected.
   {{judged_note}}
3. {{workflow_path}} - a Workflow script already written for this plan. Its
   phases are the plan's phases.
   {{visuals_note}}

Then run it: read {{workflow_path}} and call `Workflow` with its full contents
as the `script` argument, verbatim. Do not paraphrase it, do not rewrite it
from the plan, and do not author a new one.

Before you run it, read it and check it against the plan. It was written by a
planning agent, not proven by execution. If a phase's verification command is
wrong, a dependency between phases is missing, or the plan changed after the
script was written, fix the script first and say what you changed and why.
Adjusting it is expected; replacing it wholesale means something is wrong with
the plan, so stop and say so instead.

Run the whole workflow end to end in one Workflow call and report once at the
end: what landed, the verification result, and anything the plan got wrong.
The workflow stops on its own when a phase fails verification; when it does,
report and wait. If I ask to be checked in with, run one phase at a time
instead by passing args {only: ["<phase title>"]}, and report after each.
A check-in run skips the final Verify; add verify: true to the last one.

Ground rules:

- The plan is a plan, not a contract. If reality contradicts it, stop and say
  so rather than forcing the plan through. Record the divergence.
- Anything the plan leaves genuinely open is a question for me, not a guess
  for you. Ask with AskUserQuestion, the way the plan itself was built.
- Honor this session's cf merge mode for anything that pushes, opens a PR, or
  merges.

Repo: {{repo_path}}
Goal in one line: {{goal_one_liner}}

{{stack_note}}
```
