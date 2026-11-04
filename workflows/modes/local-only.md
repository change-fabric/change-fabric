# CF local-only

When invoked as `{{skill:local-only}}`, select `local-only` for this session.
Acknowledge the choice in one line and continue the task.

Keep changes on disk. Do not push, create a pull request, or merge. Requested comments on existing PRs are permitted.

Ask the installed host adapter to persist the choice when available. Without
an adapter, keep it in conversation and compaction summaries. Check runtime
context on resume. A child session inherits its parent's mode until explicitly
changed; independent sessions must not change one another's mode.

Use `{{skill:cf}}` to choose another mode. This sets workflow intent;
it never changes host permissions or sandbox settings. Shell guards are advisory.
