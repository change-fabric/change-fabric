---
name: cf:admin-bypass
description: Sets the session merge mode to admin bypass, so the agent pushes, opens a PR, and squash-merges it via admin bypass once CI is green.
---

# CF Admin Bypass

Trigger: `/cf:admin-bypass`.

A `UserPromptSubmit` hook (`mode_command.rb`) has already persisted this
session's merge mode as `admin-bypass` and restated it back to you. This file
states what the mode means going forward.

## Applying the mode

After completing work, push, open a PR, then run
`gh pr merge --squash --admin` once CI is green. No additional Bash
restriction applies under this mode: admin bypass is the mode that permits
both the push and the merge.

A `PreToolUse` hook (`merge_mode_guard.rb`) backs this by not restricting
`git push` or `gh pr merge` while this mode is active. It is an advisory
guardrail, not a sandbox, so honoring the mode in your own actions is still
the primary mechanism.

## Changing the mode

Run `/cf:local-only`, `/cf:merge-ready`, `/cf:yolo`, or `/cf` to change the
mode mid-session.
