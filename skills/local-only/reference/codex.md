# CF Local Only in Codex

When invoked as `$cf-local-only`, set merge mode to `local-only` in the current
conversation. Acknowledge it in one line, then continue the task.

Keep changes on disk. Never push or open a new PR. Requested review comments
on an existing PR are permitted.

Keep this mode in subsequent turns and compaction summaries until the user
changes it. No hook has persisted it; do not claim it was written to disk.
Use `$cf-merge-ready`, `$cf-admin-bypass`, `$cf-yolo`, or `$cf` to change it.
