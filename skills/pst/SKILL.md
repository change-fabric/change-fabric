---
name: pst
description: Set and enforce the session merge mode (local only, merge ready, or admin bypass). Re-invoke to change the mode mid-session.
---

# PST Merge Mode Shim

The merge-mode question is injected automatically by the `SessionStart` hook
(`session_start.rb`) on session start, resume, `/clear`, and compaction. The
chosen mode is persisted per session (a `PostToolUse` hook records the
`AskUserQuestion` answer to `~/.claude/pst/sessions/<session_id>/merge-mode`)
and restated every turn by a `UserPromptSubmit` hook, so it survives
compaction. Once a mode is persisted, `SessionStart` restates it instead of
re-asking. This file is the manual `/pst` re-invoke path plus the rules for
applying the chosen mode.

## /pst

Call `AskUserQuestion` to re-set the session's merge mode:

**Question:** "How should I handle changes from this session?"
**Header:** Merge mode
**Options:**

1. **Local only:** No push, no PR. Changes stay on disk.
2. **Merge ready:** Push branch, open PR, ensure CI is green. You merge manually.
3. **Admin bypass:** Push branch, open PR, squash-merge immediately via admin bypass once CI is green.

Acknowledge the choice in one line, then proceed.

## Applying the mode

- **Local only:** Never `git push`, never open PRs.
- **Merge ready:** After completing work, push and open a PR. Stop, do not merge.
- **Admin bypass:** After completing work, push, open a PR, then run `gh pr merge --squash --admin`.

A `PreToolUse` hook (`merge_mode_guard.rb`) backs these rules by denying the
obvious violating Bash commands for the active mode (`git push` under Local
only, `gh pr merge` under Local only or Merge ready). It is an advisory
guardrail, not a sandbox: it matches on the command text and is bypassable, so
honoring the mode in your own actions is still the primary mechanism.
