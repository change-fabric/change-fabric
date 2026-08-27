Fill every `{{placeholder}}` from this run, then print the fenced block below
as the final message. Do not add commentary inside the fence.

Every path placeholder here (`{{plan_path}}`, `{{goal_path}}`,
`{{workflow_path}}`, `{{repo_path}}`) takes the tilde form (from
`plan_paths.rb`'s `_tilde` fields or its `tildeize` verb), never the literal
absolute path: this block is meant to be pasted into a fresh session, possibly
on another machine, and a literal `/Users/pxt/...` or `/home/exe/...` breaks
the moment the same account's home sits under a different literal path there.

```markdown
Execute the plan at {{plan_path}}.

Read these three files first, in this order:

1. {{goal_path}} - what done looks like and why it matters. Short by design.
2. {{plan_path}} - the full technical plan. This is the source of truth for
   what to build. Its "Decisions (settled, do not re-litigate)" section
   records answers the user already gave during planning. Those are fixed.
   Do not reopen them, do not offer alternatives they already rejected.
3. {{workflow_path}} - a Workflow script already written for this plan. Its
   phases are the plan's phases.

Then run it: read {{workflow_path}} and call `Workflow` with its full contents
as the `script` argument, verbatim. Do not paraphrase it, do not rewrite it
from the plan, and do not author a new one.

Before you run it, read it and check it against the plan. It was written by a
planning agent, not proven by execution. If a phase's verification command is
wrong, a dependency between phases is missing, or the plan changed after the
script was written, fix the script first and say what you changed and why.
Adjusting it is expected; replacing it wholesale means something is wrong with
the plan, so stop and say so instead.

Check in with me at phase boundaries. Report what landed, what is next, and
anything the plan got wrong, then wait for my go-ahead. Do not run the whole
workflow end to end unsupervised.

Ground rules:

- The plan is a plan, not a contract. If reality contradicts it, stop and say
  so rather than forcing the plan through. Record the divergence.
- Anything the plan leaves genuinely open is a question for me, not a guess
  for you. Ask with AskUserQuestion, the way the plan itself was built.
- Honor this session's cf merge mode for anything that pushes, opens a PR, or
  merges.

Repo: {{repo_path}}
Goal in one line: {{goal_one_liner}}
```
