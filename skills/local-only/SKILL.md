---
name: cf:local-only
description: Sets the session's merge mode to local only, so changes stay on disk with no git push and no new PR. Re-invoke to keep it in effect; run cf:merge-ready, cf:admin-bypass, or cf:yolo to change it, or cf to pick both axes at once.
---

# CF Local Only

Trigger: `/cf:local-only`.

The handler hook (`mode_command.rb`) has already persisted `local-only` as this
session's merge mode to `~/.claude/cf/sessions/<session_id>/merge-mode` and
injected a one-line confirmation. Acknowledge the mode in one line, then
proceed.

## Applying the mode

Never `git push`, never open a new PR. Changes stay on disk. Posting review
comments to a PR that already exists on GitHub is neither a push nor a merge
and is not restricted by this mode.

A `PreToolUse` hook (`merge_mode_guard.rb`) backs this rule by denying `git
push` while local only is active. It is an advisory guardrail, not a sandbox:
it matches on the command text and is bypassable, so honoring the mode in your
own actions is still the primary mechanism.

## Changing the mode

Run `/cf:merge-ready`, `/cf:admin-bypass`, or `/cf:yolo` to switch directly, or
`/cf` to re-pick both the merge mode and away mode together.
