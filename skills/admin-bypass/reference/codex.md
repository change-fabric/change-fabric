# CF Admin Bypass in Codex

When invoked as `$cf-admin-bypass`, set merge mode to `admin-bypass` in the
current conversation. Acknowledge it in one line, then continue the task.

After completing work, push a feature branch, open a PR, and wait for green
CI. Then squash-merge it with `gh pr merge --squash --admin`, subject to the
repository's rules and the user's authorized scope.

Keep this mode in subsequent turns and compaction summaries until the user
changes it. No hook has persisted it; do not claim it was written to disk.
This changes workflow intent, not Codex permissions or sandbox settings.
Use `$cf-local-only`, `$cf-merge-ready`, `$cf-yolo`, or `$cf` to change it.
