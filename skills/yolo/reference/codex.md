# CF Yolo in Codex

When invoked as `$cf-yolo`, set merge mode to `yolo` in the current
conversation. Acknowledge it in one line, then continue the task.

After completing work, commit and push directly to the task's target branch.
Never open a new PR. Merging an existing PR is permitted within the user's
authorized scope and repository rules.

Keep this mode in subsequent turns and compaction summaries until the user
changes it. No hook has persisted it; do not claim it was written to disk.
This changes workflow intent, not Codex permissions or sandbox settings.
Use `$cf-local-only`, `$cf-merge-ready`, `$cf-admin-bypass`, or `$cf` to change it.
