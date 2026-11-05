# CF merge-ready

When invoked as `{{skill:merge-ready}}`, select `merge-ready` for this session.
Acknowledge the choice in one line and continue the task.

Push a feature branch, open a pull request, and ensure CI is green. Stop before merging. Do not push directly to the trunk. Requested comments on existing PRs are permitted.

Ask the installed host adapter to persist the choice when available. Without
an adapter, keep it in conversation and compaction summaries. Check runtime
context on resume. A child session inherits its parent's mode until explicitly
changed; independent sessions must not change one another's mode.

Use `{{skill:cf}}` to choose another mode. This sets workflow intent;
it never changes host permissions or sandbox settings. Shell guards are advisory.
