# CF Merge Ready in Codex

When invoked as `$cf-merge-ready`, set merge mode to `merge-ready` in the
current conversation. Acknowledge it in one line, then continue the task.

After completing work, push a feature branch, open a PR, and ensure CI is
green. Stop before merging. Do not push directly to the trunk or merge a PR.
Posting requested review comments on an existing PR is permitted.

Keep this mode in subsequent turns and compaction summaries until the user
changes it. No hook has persisted it; do not claim it was written to disk.
This changes workflow intent, not Codex permissions or sandbox settings.
Use `$cf-local-only`, `$cf-admin-bypass`, `$cf-yolo`, or `$cf` to change it.
