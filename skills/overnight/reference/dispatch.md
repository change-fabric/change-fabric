# Dispatch protocol

Every external side effect of a cf:overnight run is one action with a stable
id `<unit>:<step>:<attempt>`. Its journal records, in order:

1. `planned`: intent plus a client idempotency key, persisted before the request.
2. `dispatched`: the response, with external ids (PR number, tag, run id, snapshot id, reservation id).
3. `observed-complete`: the outcome, with evidence.

`uncertain` replaces a missing response: a crash, a cancellation, or a lost
reply. It is never read as complete.

Resume reconciles every action that is not `observed-complete` before anything
else, using the lookup below. A kind with neither idempotency nor lookup cannot
be retried after an uncertain dispatch: the unit goes to handed-over.

The table is `OvernightStore::DISPATCH`; `test/overnight_skill_test.rb` keeps
the two in step.

| Kind | Idempotency | Lookup |
|---|---|---|
| push | expected remote head sha | git ls-remote |
| pr-open | head branch (one open PR per head) | gh pr list --head |
| merge | gh pr merge --match-head-commit | gh pr view --json state,mergeCommit |
| tag-push | tag name bound to one sha | git ls-remote --tags |
| flag-change | compare-and-set where the adapter offers it | flags adapter read-back |
| deploy-trigger | none | gh run list --workflow --commit |
| backup | correlation key in the dump file name | dump file plus checksum |
| snapshot | correlation key in the snapshot name | provider snapshot list |
| window | open or close is a state set | maintenance command status |
| destructive-write | none | none |
| paid-call | content key cache | spend.json by reservation id |

Crash points tested per kind once the harness lands: after remote acceptance,
before response persistence, and a lost response.
