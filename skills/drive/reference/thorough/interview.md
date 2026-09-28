# The thorough-mode interview

Read `skills/plan/reference/interview.md` first. Its rules apply unchanged here:
what earns a question, the shape of a question (recommendation first, labelled
`Recommended:`), up to four decisions per `AskUserQuestion` call, at most three
rounds, and the verbatim ledger that becomes plan.md's
`## Decisions (settled, do not re-litigate)`. This file adds only what a
thorough plan must settle, and the default for each.

You run the interview in this session, never in a subagent.

## Seeding from the last plan

Project facts recur every release: the gate chain, flaky tests, the env keys to
blank for safe QA, hosts nobody may contact, local ports and database names,
role accounts. When SKILL.md step 3 finds an earlier thorough plan in the same
area, its `## Project profile` section is the starting point. Do not re-ask a
profile fact the diff gives no reason to doubt. Ask only where the diff changed
something (a new service, a new billable integration, a renamed script), and
record in the ledger that the rest was carried from `<earlier plan dir>`.

## The tier check (before any research)

Classify from the local diff, never from `gh pr diff` (it fails with HTTP 406
above 300 files):

```bash
git -C <repo> fetch origin
git -C <repo> diff --name-only <base>...<head> > <scratchpad>/changed.txt
wc -l < <scratchpad>/changed.txt
grep -iE '<pattern>' <scratchpad>/changed.txt
```

Risk areas, each a case-insensitive path pattern, extended by the project
profile's own globs when one exists:

| Area | Pattern |
| ---- | ------- |
| money | `pay|billing|invoice|charge|refund|ledger|price|checkout|balance|credit|stripe|wallet` |
| auth | `auth|session|login|oauth|jwt|password|permission|policy|role|middleware|proxy` |
| pii | `email|sms|notif|profile|address|export|consent|privacy|upload` |
| schema | `migrat|schema|drizzle|prisma|\.sql$|db/` |

- **Low risk**: under about 30 files and no area matched. Recommend `/cf:drive quick`
  and stop: it already reviews, QAs, fixes on the PR branch, predicts CI,
  pushes, waits for green and approves. Ask once, `/cf:drive quick` first; the override
  proceeds as `pr-high`.
- **pr-high**: one PR with any area matched, or any PR the user overrides into
  it.
- **release**: a range between long-lived branches (for example
  `production..development`), whatever its size.

A path match is a default, not a verdict: show the matched files per area when
you ask the user to confirm the tier.

## What every thorough plan must settle

Each item below is a decision. Take the default without asking when the
evidence settles it; ask when it does not. Tier switches items on or off; the
workflow segments are the same in both tiers.

1. **Tier.** Confirm or override the check above.
2. **Review scope and units.** Default: one unit per risk area the diff
   touches (money, auth and security, schema and SQL, UI primitives, runtime),
   plus general units for the rest by path. A matched money, auth, PII or
   schema area must have a unit of kind `money`, `security` or `schema`; the
   workflow refuses a plan without one. Each unit gets scope commands (local
   ranges), a focus, the shared exclusions (each with its evidence) and the
   known-deferred list. Ask about any changed path the units do not cover.
3. **Severity scale and what blocks.** Default: blocker, should-fix, nit, with
   the meanings in `workflow-template.js`; blocker and should-fix block. The
   rule that who can trigger a bug never lowers its severity is fixed, not a
   question.
4. **QA depth.** Roles, viewports (default desktop 1280x800 and 390x844),
   themes (default every theme the app ships), and the lanes. Lanes run one at
   a time; that is fixed.
5. **Where write-QA runs, and what must never be contacted.** Options: a local
   copy of prod data, a seeded local database, or staging (read-only unless the
   owner says otherwise). Default: a local copy when the change reads real data
   shapes (migrations, backfills, money states), else seeded. A local copy holds
   PII: it stays local, mail goes to a capture server, SMS is off, billable keys
   are blanked, and it is deleted afterwards. Name the never-contact list
   explicitly: production hosts, real people, billable services. Every sweep
   command against a named target carries `--target-url` and a `--health-url`
   under it; the workflow refuses one without.
6. **Merge mode and who authorizes merges.** The session's cf merge mode
   governs pushes and PRs. Ask who authorizes each merge and the exact merge
   command. `pr-high` fixes are commits on the PR's own branch; `release` fixes
   are separate PRs against the integration branch.
7. **Pre-merge verification.** Default on in both tiers: a fresh adversarial
   review of each fix's full diff for two rounds, then its delta only, plus one
   QA pass over all open fixes merged together locally on a throwaway seeded
   database.
8. **Deploy scope and freeze** (release tier). Whether a deploy is in scope;
   if so, the freeze (what is frozen, who announces it), the rehearsal, the
   prod-day checklist and the rollback levels. Steps only the main thread may
   do (database operations, merges, prod) become `mainThread` pointers.

## Counts

Never write a total the plan does not itemize. If plan.md says "29
statements", the list beside it must have 29 entries, and the number comes
from counting the list, not from memory. When a total cannot be itemized yet
(it depends on generated output), say what to count and when, not a number.
