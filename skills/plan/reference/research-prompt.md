Fill every `{{placeholder}}`, then pass the result as the `Agent` prompt. The
research section is for the agents at step 4; the writing section is for the
single agent at step 7. They are never the same agent: research happens before
the interview, writing happens after it.

## Research agent (step 4, writes nothing, asks nothing)

```
Research in support of a plan that has not been written yet. Someone else will
write it, after the user has answered the questions you surface.

Question: {{sub_question}}
Larger goal: {{goal_description}}
Repo or area: {{repo_path}}

Investigate thoroughly: read the real files, run read-only commands, check how
the thing actually works rather than how it is documented to work. Cite
absolute file paths for anything load-bearing. Form your own point of view;
"here are some options" is not a finding.

Write no files.

You do not have AskUserQuestion. Do not try to call it and do not design
around having it. Your job is to surface the questions, not to ask them.

Return two things.

1. FINDINGS. What is true, what you recommend and why, and what you could not
   settle. Name the existing conventions you found, because a plan that
   invents a new one where the repo already has an answer is a defect.

2. CANDIDATE QUESTIONS. Every decision this plan needs that your research
   cannot settle: preference, priority, risk appetite, naming, scope
   boundary, or a tradeoff with no objectively right side. For each:

   - Decision: a 1 to 12 character name for it.
   - Why it is open: the fact from your research that makes it a real fork,
     not a rhetorical one.
   - Options: two to four, each with the concrete consequence for the plan.
   - Your recommendation: which one, and the reason in one clause.
   - What changes if the user picks otherwise.

   A decision you settled from evidence is a FINDING, not a candidate
   question. A decision you settled by assumption is a candidate question,
   and you must say which assumption you made.

   Returning zero candidate questions means you claim every open decision was
   settled by evidence. That is rare. Check your findings for silent
   assumptions before you claim it.
```

## Writing agent (step 7, lands all three files)

```
Write a plan that is already decided. The research is done and the user has
answered the open questions; your job is to render that into files, not to
re-open it.

Goal: {{goal_description}}
Repo or area: {{repo_path}}
Plan directory (already created): {{plan_dir}}

DECISIONS LEDGER (the user's own answers, authoritative):
{{decisions_ledger}}

RESEARCH FINDINGS:
{{research_findings}}

Where the ledger and a finding disagree, the ledger wins. Do not soften a
decision the user made into an option, and do not add an alternative they
already rejected.

Write exactly three files.

1. {{plan_dir}}/plan.md - the full technical plan. No length cap. It must be
   detailed enough that a separate agent, with none of your context, can turn
   it directly into real work. That means:
   - a `## Decisions (settled, do not re-litigate)` section reproducing the
     ledger, each decision naming the answer it came from. This section comes
     early, before the phases, and is the reason the executing session does
     not reopen a settled call;
   - exact file paths for everything created or edited;
   - exact commands, config, and code where the code is what makes the plan
     unambiguous;
   - how the change is verified (the actual test, build, or check command);
   - a phased rollout, each phase small enough to be one commit or one PR,
     ordered so each phase leaves the tree working;
   - the failure modes and what to do about each.
   Anything still genuinely open after the interview is recorded as an open
   question with your default, not silently resolved.

2. {{plan_dir}}/goal.md - the short vision statement. What done looks like and
   why it matters. Deliberately no implementation detail: it exists to orient
   a reader in under two minutes.

   HARD CAP: 4000 characters. Before writing it, count the characters of your
   draft. If it is over, trim by cutting implementation detail (that content
   belongs in plan.md), not by compressing prose into abbreviations or
   dropping the "why". Re-count after trimming.

3. {{plan_dir}}/workflow.js - a runnable Workflow script that executes the
   plan. Read {{skill_dir}}/reference/workflow-template.js first: it carries
   the Workflow tool's authoring contract and the failure modes that only
   surface at run time. Instantiate it against this plan:
   - `meta.phases` are the plan's own phases, with the plan's own titles, in
     the plan's own order. Not "Phase 1, Phase 2".
   - every `phase("X")` call matches a `meta.phases` title exactly;
   - every phase agent gets the plan's real instruction and the plan's real
     verification command, not a paraphrase;
   - `parallel()` only where the plan's units are genuinely independent;
   - nothing nondeterministic in the script body and no tool calls there: no
     wall-clock read, no randomness. plan_check.rb greps for the literal call
     syntax, in comments too.
   A template shipped back with its placeholders intact is a failure.

Before you report done, run:

    ruby ~/.claude/cf/bin/plan_check.rb {{plan_dir}}

It must exit zero. If it does not, fix what it names and run it again.

Authored-output rules for all three files: no em-dash, no unicode bullet
character (a plain "-" list is fine), no ellipsis character, no smart or curly
quotes. Plain ASCII hyphens and straight quotes only. Write plainly, no
marketing language.

Report back: all three absolute paths, goal.md's character count, the phase
titles in workflow.js, and a short summary of the plan's shape.
```
