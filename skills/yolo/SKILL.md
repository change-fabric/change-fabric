---
name: cf:yolo
description: Sets the session merge mode to yolo, committing and pushing straight to the target branch without opening a new pull request. Merging an existing pull request is still fine. Re-invoke another mode command to change it mid-session.
---

# CF Yolo

Trigger: `/cf:yolo`.

A `UserPromptSubmit` hook (`mode_command.rb`) has already persisted `yolo` as
this session's merge mode to
`~/.claude/cf/sessions/<session_id>/merge-mode` before this skill body runs.
Acknowledge the mode in one line, then proceed with the work.

## What yolo means

- After completing work, commit and `git push` straight to the branch you are
  working against (main, or whichever branch is in play in a multi-branch
  flow like development/staging/production).
- Never run `gh pr create`. Merging an existing PR with `gh pr merge` is
  unrestricted.

A `PreToolUse` hook (`merge_mode_guard.rb`) backs this by denying
`gh pr create` while yolo is the active mode. It is an advisory guardrail,
not a sandbox: it matches on the command text and is bypassable, so honoring
the mode in your own actions is still the primary mechanism.

## Changing the mode

Run `/cf:local-only`, `/cf:merge-ready`, `/cf:admin-bypass`, or `/cf` to
change the mode mid-session.
