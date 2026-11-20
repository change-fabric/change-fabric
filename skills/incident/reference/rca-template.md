# RCA: <short title>

Date: <YYYY-MM-DD, detection day>
Environments: <production, staging, ...>
Impact: <who and what was affected, for how long, measured not guessed>
Issue: <link to the tracking issue, or none>
Incident: <id from `incident_store.rb`>

## Detection

How the problem surfaced (report, alert, user), the first timestamp, and the
probe that reproduces it. Link the evidence file under `evidence/`.

## What happened

The chain of cause, in order, from the change that introduced it to the
symptom. Name the bad release and the last good one. Separate what was
observed from what is inferred.

## Mitigation

What stopped the bleeding, who approved each production step, and the serving
version afterward. Cite the ops in `ops.json` (op id, runbook or runner). State
plainly if a migration could not roll back.

## Fix

The hotfix: PR URL, merge SHA, the version now serving and how that was read
(`deploy_api` or `version_endpoint`). Say how it also landed on main.

## Prevention

What makes this class of failure harder to repeat: a check, a gate, a test, an
alert. Each item is a follow-up.

## Follow-ups

One line per prevention item with its tracking URL, or `accepted untracked by
<who>`. No item stays a draft at close.
