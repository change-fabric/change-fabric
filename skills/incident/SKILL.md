---
name: cf:incident
group: workflow
description: Runs the production incident cycle for a repo, kept outside git. Opens a record in the cf incidents tree, drafts a rollback script from the repo's own runbook for the human to run, gathers read-only evidence into a timeline, scopes a hotfix through cf:drive quick and cf:change, verifies production read-only, writes an RCA, and tracks prevention follow-ups to closure. It never runs a prod command and never pushes a tag. Invoked by name.
---

# CF incident

Trigger: `/cf:incident <what broke>` (optionally `--repo <dir>`,
`--client <name>`, `--resume <id>`).

Question: can a stranger reading only the incident directory see what broke,
what was done about it, who approved each production step, and what now stops
it recurring?

The record lives at `~/.claude/cf/incidents/<repo>/<YYYY-MM-DD-slug>/`
(`CF_INCIDENTS_DIR` overrides the root) and holds `incident.json`,
`timeline.md`, `ops.json`, `rca.md` and `evidence/`. It is never committed
into the consumer repo: `scripts/incident_store.rb` refuses a root inside a git
work tree or under the repo checkout or any path in `CF_KNOWN_REPO_ROOTS`
(colon-separated). Every command below is
`ruby ~/.claude/cf/bin/incident_store.rb <command> --repo <slug> ...`, takes
`--at <ISO 8601 UTC>`, and `--id` takes the exact id or a unique prefix.

## Hard limits

- Never run a production command and never push a tag. Draft each one into a
  script under `~/.claude/cf/manual/` and hand it over (RUN NOW callout, an
  absolute path in a code block, no y/N prompts). A tag is always the human's.
- The store records approvals; it never grants one. `--approved-by` is the
  human who approved, reported by them.
- Flag-rollout incidents (the breach is a progressive-delivery rollout) belong
  to delivery triage (`change_policy.delivery.rollouts.<r>.on_breach.triage`).
  Record them and stop.
- Auth failures are not retried with another login. Without Patrick's approval
  for a session, a blocked check is inconclusive.

## Protocol

1. **Open.** `create --repo <owner/name> --slug <s> --at <iso> [--client C]
   [--severity sev2]` prints the id. Append the report to the timeline. Record
   the broken check as a reproducible probe: `set --id <id> --probe '<command
   or URL>' --probe-expected '<result>' --at <iso>`. Keep the failing output in
   `evidence/`.
2. **Mitigate.** Read the repo's rollback runbook (`docs/DEPLOYMENT.md`,
   `RUNBOOK*`, `docs/runbooks/`); see `reference/rollback-runbook.md`. Draft
   the exact commands into a manual script, log it with `record-op --kind
   rollback --via runbook --commands-file <script>`, and hand it to Patrick.
   When he reports his approval, `update-op --status approved --approved-by
   <who>`, then `running`, then `succeeded` or `failed` with `--result`. No
   runbook means no invented command: page Patrick with the evidence. When the
   repo carries the bounded runner and its `redeploy_previous` op exists, a
   later phase of this skill requests it; until then the runbook is the path.
3. **Diagnose.** Read-only evidence into `evidence/`, one timeline line per
   finding. Spawn evidence workers with model {{model:worker}}. The diagnosis
   text is roasted by the critic role ({{model:critic}}) with `roast.rb` before
   it drives a fix; the bar comes from `roast.rb settings`, never a number
   written here.
4. **Hotfix.** Detect the repo's documented hotfix path (for example a
   `hotfix/vX.Y.Z` branch from the last prod tag); else a normal PR into main.
   Either way run cf:drive quick and cf:change, and make sure the fix also
   lands on main. Scope the fix before writing code: check the diff's paths
   against the one-way doors (destructive_data, contracts_and_auth,
   money_and_sends, infra, gate_config). One-way-door stop: when any path
   matches, stop before writing code and ask Patrick with AskUserQuestion. The
   PR body carries the line `Incident: <id>`. Record the PR URL and merge SHA
   with `set --pr-url ... --merge-sha ...`. Advisory limit: 2 attempts or 60
   minutes, then page Patrick and leave the incident at `mitigated`.
5. **Tag and deploy.** Hand Patrick a tag script under
   `~/.claude/cf/manual/`. Record it as an op (`--kind tag`). Never push a tag.
6. **Verify.** Read-only. Rerun the probe, and read the serving version from
   its named source: `set --serving-version <v> --serving-source
   deploy_api|version_endpoint` (a tag alone never establishes it) plus
   `--fix-version <v>`. Record `--probe-result pass` only while the fix is the
   serving version, and one `--regression <name>=pass|fail` per P0 row. Then
   `set --status verified`; the store refuses it unless every rule holds.
   Inconclusive evidence, including an auth failure, is recorded with
   `--probe-result inconclusive|auth_failure`, which sets `unverified`: page
   Patrick.
7. **RCA.** Fill `rca.md` from `reference/rca-template.md`. File each
   prevention item with `follow-up add --title T [--url U]`, then link them in
   `rca.md`. An item without a URL stays `drafted`: draft its ticket (a
   `gh issue create` command, or the repo's tracker) for Patrick, roast the
   body first, and never file it yourself. `follow-up update --n K --url U`
   tracks it, or `--accepted-untracked --by <who>` records Patrick's acceptance.
8. **Report.** The client summary and evidence PDF arrive in a later phase.
   Until then, tell Patrick the incident is ready to report. After he sends
   whatever he sends, `set --status reported`.
9. **Close.** Update `rca.md` after the verified transition, then `close`. It
   refuses unless status is `reported`, every follow-up is tracked or accepted
   untracked, `hotfix.pr_url`, `hotfix.merge_sha` and `hotfix.serving_version`
   are recorded, and `rca.md` was modified after verified.

## Status

`open` to `mitigated` or `fixing`; `mitigated` to `fixing`; `fixing` to
`verified` or `unverified`; `unverified` to `fixing` or `verified`; `verified`
to `reported`; `reported` to `closed` (only via `close`). `set` cannot jump.

## Models

Evidence gathering and hotfix scoping run as {{model:worker}}. The RCA prose
is written as {{model:author}}. Diagnosis review is {{model:critic}}.
