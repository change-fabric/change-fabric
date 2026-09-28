# cf:readiness validation

## Source case

The source case is a release PR (development -> production, 788 files, 51
squash commits) taken to production in September 2026. Its planning set was
written with `cf:plan`, and its `workflow.js` was patched about twenty times
during the run. Every patch was a lesson paid for once. This skill's engine
exists so the next run starts with those patches.

## What the authoring session proved

This was a dry run. It used no live repo and no real agents.

1. **The template regenerates the source case's workflow.** The session filled
   the template's PLAN block from the as-run script: 8 review units, 7 QA
   lanes (setup first), 5 flakes, 3 main-thread steps, the gate chain, and the
   never-contact list. It then ran SKILL.md step 8 against a plan directory
   holding the source case's own plan.md and goal.md. `plan_check.rb` exited
   0, the engine diff was empty, and no `FILL:` or `{{` placeholder was left.
2. **Every segment dispatches.** A node harness stubbed `agent`, `parallel`,
   `phase` and `log`, then called each segment with representative args. It
   recorded every agent prompt and checked it for the guard text:

   | Scenario | Agents that ran | Outcome |
   | -------- | --------------- | ------- |
   | `scope` | 1 | tips and uncovered files; next: review |
   | `review` | 8 reviewers in parallel, then the ledger | next: audit or fix |
   | `fix` `plan-batches` | 1 (opus) | batches go to the owner first |
   | `fix` `apply`, one batch with `revise: true` | 2 in sequence, then the ledger | the revise prompt reuses the open PR; the planner notes arrive |
   | `fix` `verify`, round 1 | 2 reviewers plus one combined QA | full diff `base...branch`; QA merges both branches |
   | `fix` `verify`, round 3 | 1 reviewer plus QA | delta `lastVerifiedSha..branch` only |
   | `gate` | gate, then the ledger | next: qa |
   | `qa`, a lane note reading "sent no mail" | all 7, one at a time | no halt |
   | `qa`, a lane returning `SAFETY STOP: ...` | setup, p0, p1 | halts after p1 |
   | `qa`, setup failing | setup | halts all QA |
   | `audit` check, then apply | 1 (opus), then the ledger | candidates become owner questions |
   | `handoff` with a carried lane | 1 (opus) | the prompt demands an `OWNER APPROVAL` line |
   | `prod` | none | pointer only |

3. **The plan checks catch the source case's own mistakes.**
   - Dropping `--health-url` from the staging sweep makes the workflow refuse
     to run, before any agent starts. In the source case, that omission sent
     health polls to production.
   - The check also flagged the as-run a11y lane: it called `change_run.rb`
     without `--no-publish`, which would upload artifacts from a QA lane. The
     source case did not catch this.

## Lessons and where the engine carries them

| Lesson from the run | Now carried by |
| ------------------- | -------------- |
| `gh pr diff` failed with HTTP 406 above 300 files | SKILL.md step 1 and every reviewer prompt: local git ranges only |
| Reviewers rated a double-post and a misdirected PII email as nit because only an admin could trigger them | `SEVERITY_TEXT`: who can trigger a bug never lowers its severity; the `audit` segment re-checks every row below blocker |
| One fix took four rounds, and restoring a confirm made bounced checks postable again | `fix` `verify`: an adversarial full-diff review, then the delta only after `FULL_DIFF_ROUNDS` |
| Fix PRs needed verifying before merge (added to the as-run script mid-run) | `verify` runs pre-merge by default, plus one QA pass over all open fixes merged together locally |
| Owner-folded nits and constraints had to reach the fix agent | `args.extraIds`; `notes` is required on every batch |
| Revising an open PR opened a new one | `batch.revise` reuses the branch, worktree and PR |
| Fixes without proof | `failingFirst` is required in the apply schema |
| Schema changes inside fixes | `PLAN.fix.schemaPaths`: a hard stop and an escalation |
| Parallel agents on one database and Docker crashed Docker | no-fork rule; lanes run in a `for` loop, never `parallel` |
| QA env needed extra blanking mid-run (app URL, cache, solver keys) | `PLAN.qa.setup` lists it up front; every lane re-runs the safety probe |
| A mail/sms regex stopped a run on "sent no mail" | halts only on `startsWith("SAFETY STOP: ")` |
| A sweep sent health checks to production | `planProblems`: a named target needs `--health-url` under it, and QA sweeps need `--no-publish` |
| The main thread carried lane results forward alone | `carryForward` is release-tier only; the handoff is NOT READY without an `OWNER APPROVAL` line in run-log.md |
| The diffs to read missed a fix's files | the handoff computes diffs from changed paths plus each fix commit's paths |
| Classifier denials (a roster write, a third-party image, prod DB access from a subagent) | the rules forbid retrying or routing around; `blockedFlows[].needsOwner` and `ownerQuestions` |
| Known and new flakes, including a failed production build | `PLAN.flakes` with kind `test` or `build`: one retry; a new one is logged as FLAKE-n, not investigated |
| The plan said 41 statements; its own list summed to 29 | PLAN holds lists, never totals; interview.md "Counts" |
| Check-ins | every segment returns `nextStep` and `ownerQuestions`; the handoff prompt stops at each boundary |
| Four writers edited the findings files, and the main thread rewrote the handoff verdict | `ledger()` is the only writer of four files; the handoff agent rewrites its own; the main thread writes run-log.md only |
| A reclassified row stayed in the Nits table, and header counts went stale | severity is a column; counts are recomputed from rows |
| gate-log.md missed fix-branch gates, where a new flake first showed | `apply` gate rows go to gate-log.md too |
| qa-report.md was written newest first | the template fixes the order, oldest first |

## Where the engine differs from the as-run script

Each difference is deliberate:

- **Code-producing work has no segment.** The source case's `migration-pr`
  segment generated code. That is `cf:plan` work, or a fix batch.
- **Post-merge `rereview` is gone.** Pre-merge `verify` replaced it; the source
  case made the same switch mid-run.
- **Pre-merge QA merges all open fixes together.** The source case QA'd each
  fix at its own head.
- **`audit` is new.** The source case reclassified by hand at handoff.
- **An unknown merge mode means local-only.**

## What the session could not prove

- A real `Workflow` run with real agents.
- The interview itself.
- A `pr-high` plan on a live repo.

Run the prompt below on a real project to close those.

---

## Prompt to paste

Validate `cf:readiness` (`skills/readiness/SKILL.md`) on a real repository.

1. Pick a merged PR under 30 files that touches no money, auth or schema
   paths. Run `/cf:readiness <n>`. Confirm step 2 recommends `cf:drive` and
   writes nothing.
2. Pick a PR that touches auth or money. Run `/cf:readiness <n>` and answer
   the interview. Confirm:
   - The tier is `pr-high`.
   - Every touched risk area has a unit of the matching kind.
   - Step 8's checks all pass.
   - The landed `workflow.js` returns "PLAN failed its checks" if you delete
     that unit.
3. Execute the handoff prompt in a fresh session through `review`, `fix`
   (`plan-batches`, `apply`, `verify`), `gate`, one `qa` lane, `audit` and
   `handoff`. Confirm:
   - The ledger agent is the only writer of the four ledger files.
   - The handoff reads NOT READY until the gate, the audit and the lanes are
     done at the tip.
   - No agent contacts anything on the never-contact list.

For anything wrong, silently guessed, or missing, fix the skill directly.
Commit each fix naming the scenario that surfaced it.
