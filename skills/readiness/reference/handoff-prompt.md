Fill every `{{placeholder}}` with the tilde form of each path, then print the
fenced block below as the final message. No commentary inside the fence.

```markdown
Execute the readiness plan at {{plan_path}}.

Read these first, in order:

1. {{goal_path}} - what done looks like. Short by design.
2. {{plan_path}} - the source of truth. Its "Decisions (settled, do not
   re-litigate)" section records answers I already gave. Do not reopen them.
3. {{workflow_path}} - the Workflow script for this plan. Its PLAN block is
   this run's data; its ENGINE half carries guards from earlier runs.

Run it one segment at a time: call `Workflow` with the file's full contents as
`script` and args `{ "segment": ..., "mode": ..., "expectedTip": ...,
"mergeMode": <this session's cf merge mode> }`. plan.md "Workflow segments"
lists each segment's args. If the script returns "PLAN failed its checks", fix
the PLAN block, record why in run-log.md, and rerun.

Stop at every segment boundary: report what landed, the returned nextStep and
ownerQuestions, and wait for my go-ahead. Put each open product call to me with
AskUserQuestion, your recommended option first.

Ground rules:

- Files have single writers. You (the main thread) write only
  {{run_log_path}}: tips, main-thread steps, divergences, and my rulings and
  approvals in the line formats it shows. Never edit review-findings.md,
  qa-report.md, gate-log.md, followups.md or owner-handoff.md by hand; rerun
  the segment that owns them.
- A permission or classifier denial is a question for me, never something to
  route around. After I approve, do only the narrow step I approved, yourself.
- Carrying a QA lane's result to a newer tip needs my explicit approval,
  recorded in run-log.md before the handoff runs.
- Steps the plan reserves for the main thread (database operations, merges,
  prod) return a pointer and no agent. Do them yourself, with my
  authorization where the plan says so.
- The plan is a plan, not a contract. When reality contradicts it, stop, say
  so, and record the divergence with the corrected command.
- Honor this session's cf merge mode for anything that pushes, opens a PR or
  merges.

Repo: {{repo_path}}
Change: {{target}} ({{base}} .. {{head}}), tier {{tier}}
```
