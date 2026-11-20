# Rollback from the repo's own runbook

cf:incident never invents a rollback. It finds the repo's documented one,
drafts the commands, and hands them to the human.

## Find the runbook

Search the consumer repo, in this order, and read what you find in full:

1. `docs/DEPLOYMENT.md`, then `DEPLOYMENT.md`
2. `docs/runbooks/`, then `RUNBOOK*`, then `docs/ops/`
3. The deploy workflow under `.github/workflows/` (for what the pipeline does,
   not as a source of commands to run)

No runbook found means no commands. Page Patrick with the evidence and the
list of places you searched.

## Draft the manual script

Write one file under `~/.claude/cf/manual/`, named
`incident-<id>-rollback.sh`. Rules:

- A header comment naming the incident id, the bad and good releases, and the
  runbook path and section the commands came from.
- Commands copied from the runbook only, with the release identifiers filled
  in. Nothing the runbook does not say.
- No y/N prompts. Dangerous cases are guarded in the script itself, for
  example `set -euo pipefail` and an explicit check that the target release is
  the recorded good one before it redeploys.
- A read-only health check at the end that prints the serving version.
- Migrations do not roll back. When the bad release shipped a migration, print
  that caveat in the header and stop for Patrick's decision; do not draft a
  migration reversal on your own.

Hand it over as a RUN NOW callout with the absolute path in a code block.

## Record it

    ruby ~/.claude/cf/bin/incident_store.rb record-op --repo <slug> --id <id> \
      --kind rollback --via runbook --commands-file <script> --at <iso>

The op starts `drafted`. When Patrick says he gave his approval, record the
person he names: `update-op --status approved --approved-by <who>`. Then
`running` when he starts it, and `succeeded` or `failed` with `--result` (what
the health check printed). A `drafted` op that is dropped goes straight to
`failed` with `--result abandoned`.

## Afterward

Capture the serving version from its source into `evidence/` and note it in the
timeline. The rollback is mitigation, not the fix: the incident stays open
until a hotfix is verified.
