---
name: cf
description: Set and enforce the session merge mode (local only, merge ready, admin bypass, or yolo). Re-invoke to change the mode mid-session.
---

# CF Merge Mode Shim

The merge-mode question is injected automatically by the `SessionStart` hook
(`session_start.rb`) on session start, resume, `/clear`, and compaction. The
chosen mode is persisted per session (a `PostToolUse` hook records the
`AskUserQuestion` answer to `~/.claude/cf/sessions/<session_id>/merge-mode`)
and restated every turn by a `UserPromptSubmit` hook, so it survives
compaction. Once a mode is persisted, `SessionStart` restates it instead of
re-asking. This file is the manual `/cf` re-invoke path plus the rules for
applying the chosen mode.

## /cf

Call `AskUserQuestion` to re-set the session's merge mode:

**Question:** "How should I handle changes from this session?"
**Header:** Merge mode
**Options:**

1. **Local only:** No push, no PR. Changes stay on disk.
2. **Merge ready:** Push branch, open PR, ensure CI is green. You merge manually.
3. **Admin bypass:** Push branch, open PR, squash-merge immediately via admin bypass once CI is green.
4. **Yolo:** Commit and push straight to the target branch (main, or
   whichever branch is in play in a multi-branch flow like
   development/staging/production). Never create a new PR; merging an
   existing PR is still fine.

Acknowledge the choice in one line, then proceed.

## Applying the mode

- **Local only:** Never `git push`, never open a new PR. Posting review
  comments to a PR that already exists on GitHub is neither a push nor a
  merge and is not restricted by this mode.
- **Merge ready:** After completing work, push and open a PR. Stop, do not merge.
- **Admin bypass:** After completing work, push, open a PR, then run `gh pr merge --squash --admin`.
- **Yolo:** After completing work, commit and `git push` straight to the
  branch you're working against. Never run `gh pr create`; `gh pr merge` on
  an existing PR is unrestricted.

A `PreToolUse` hook (`merge_mode_guard.rb`) backs these rules by denying the
obvious violating Bash commands for the active mode: `git push` under Local
only, `gh pr merge` under Local only or Merge ready, a direct push to the
trunk under Merge ready (an explicit `main`/`master` refspec, or a bare
`git push` while the current branch is the trunk), and `gh pr create` under
Yolo. It is an advisory guardrail, not a sandbox: it matches on the command
text and is bypassable, so honoring the mode in your own actions is still
the primary mechanism.
