Fill every `{{placeholder}}`, then pass the result as the `Agent` prompt. The
scope section is for the agents at step 4; the writing section is for the single
agent at step 7. Path conventions are cf:plan's: `{{repo_path}}` is absolute,
for the agent's own tool calls; `{{repo_path_tilde}}` is what gets written into
files.

## Scope agent (step 4, writes nothing, asks nothing)

```
Research for a thorough plan: review, fix and QA of a change, ending in a ship
or no-ship call. Someone else writes the plan after the user answers the
questions you surface.

Change: {{target}} ({{base}} .. {{head}}), tier {{tier}}
Your part: {{sub_question}}
Repo: {{repo_path}}
Project profile carried from the last plan (may be empty): {{profile}}

Use local git only: git -C {{repo_path}} diff / show / log over the range. Never
gh pr diff; it fails with HTTP 406 above 300 files. Read the real files. Cite
paths relative to the repo root. Write no files. You do not have
AskUserQuestion; surface questions instead.

Return two things.

1. FINDINGS, each backed by a command you ran:
   - The changed files grouped into review units by risk area (money, auth and
     security, schema and SQL, UI primitives, runtime, then the rest by path).
     For each unit: id, kind (review, money, security, schema), title, the exact
     scope commands, a focus naming what could break, and the files it covers.
   - Changed files no unit covers, and exclusions you propose, each with the
     evidence (codemod-only commit, generated file, docs).
   - Known-deferred candidates: issues already tracked that reviewers should
     not report again.
   - QA: the user-facing flows the diff changes, per role, with a concrete
     assertion each; which need real data shapes (a local prod copy) and which
     a seeded database covers; the env keys that would reach a real person or
     a billable service in a local run (mail, SMS, payment, AI, cloud jobs) and
     how to disable each.
   - Gate: the project's check commands in the order they must run, known
     flaky tests or build steps, and whether a CHANGE.md governs the target
     branch.
   - For a release: schema and data scripts, statement lists (itemized, never a
     bare total), the deploy path, and what a rollback can and cannot undo.

2. CANDIDATE QUESTIONS, in cf:plan's shape (Decision, why it is open, options
   with consequences, your recommendation, what changes otherwise), for
   anything evidence cannot settle, especially the eight decisions in
   {{skill_dir}}/reference/thorough/interview.md.
```

## Writing agent (step 7, lands the planning set)

```
Write a thorough plan that is already decided. Render the ledger and findings
into files; do not reopen anything.

Change: {{target}} ({{base}} .. {{head}}), tier {{tier}}
Repo: {{repo_path}} (tilde form for anything written into a file: {{repo_path_tilde}})
Plan directory (already created): {{plan_dir}} (tilde form: {{plan_dir_tilde}})
Skill directory: {{skill_dir}}

DECISIONS LEDGER (authoritative):
{{decisions_ledger}}

SCOPE FINDINGS:
{{research_findings}}

Where the ledger and a finding disagree, the ledger wins.

Write these files, using the tilde form for every path you write as text.

1. plan.md, no length cap, execution-ready, with these sections in order:
   - `## Decisions (settled, do not re-litigate)`: the ledger, each decision
     naming the answer it came from, rejected options included.
   - `## Open questions (with the default the plan uses)`
   - `## Project profile`: the recurring project facts (gate chain, flakes,
     safe-env overrides, never-contact list, local ports, database names,
     role accounts, sign-in recipe). The next thorough plan in this area
     starts from this section.
   - `## Scope`: range, tips, the changed-file list's length as counted.
   - `## Review units`, `## Severity`, `## Fix policy`, `## Gate`,
     `## QA lanes` (setup first), `## Handoff`.
   - `## Workflow segments`: each segment with its args, and each main-thread
     step.
   - Release tier with a deploy in scope: `## Rehearsal`, `## Prod-day
     checklist` (numbered steps with STOP points and owner OKs),
     `## Rollback` (levels, least drastic first).
   - `## Failure modes and responses`.
   Every total must be the length of a list beside it; count the list.

2. goal.md: what done looks like and why, no implementation detail. HARD CAP
   4000 characters; count before and after trimming.

3. workflow.js: copy {{skill_dir}}/reference/thorough/workflow-template.js, then fill
   `meta.name`, `meta.description` and the PLAN block only, from the plan. Do
   not change one character from the `// ===== ENGINE` line to the end of the
   file; the check at step 8 diffs it against the template. Replace every
   "FILL:" string. Delete optional entries the plan does not use rather than
   leaving placeholders. Put every target flag into lane commands as written
   (a sweep against a named target carries --target-url, --health-url under
   it, and --no-publish). Lists, never totals.

4. The six run files, copied from {{skill_dir}}/reference/thorough/templates/ with
   every `{{...}}` in them filled: review-findings.md, qa-report.md,
   gate-log.md, followups.md (seed "From the plan" with the plan's follow-ups),
   owner-handoff.md, run-log.md (seed "Tips" with the range ends).

Then run the checks in SKILL.md step 8 yourself and fix what they name.

Authored-output rules for every file: plain ASCII hyphens and straight quotes;
no em-dash, unicode bullet, ellipsis character or smart quotes; no agent
attribution; no connection string or secret.

Report back: the plan directory, goal.md's character count, the unit ids, the
lane ids, the main-thread step ids, and the step 8 output.
```
