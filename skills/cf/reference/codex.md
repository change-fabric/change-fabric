# CF Mode Picker in Codex

When invoked as `$cf`, ask the user for both choices using the available
question tool or plain conversation:

1. Merge mode: local-only, merge-ready, admin-bypass, or yolo.
2. Away mode: active or away.

If away mode is already on, direct the user to `$cf-active` or a direct mode
skill instead of starting the picker. Record answers in the current
conversation and acknowledge them. Do not invent a session ID or claim that
Claude hooks persisted anything.

Apply the selected mode's sibling skill: `$cf-local-only`, `$cf-merge-ready`,
`$cf-admin-bypass`, or `$cf-yolo`, and `$cf-active` or `$cf-away`. Read its
installed SKILL.md for the full behavior. Direct invocation of those skills
changes one axis without another picker.

Keep both choices in subsequent turns and compaction summaries. These are
workflow instructions; Codex permissions, approvals, and repository rules
still apply. This installer does not provide automatic mode persistence,
per-turn reminders, or hook enforcement in Codex.
