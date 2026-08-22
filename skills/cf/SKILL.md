---
name: cf
description: Set and enforce the session merge mode (local only, merge ready, admin bypass, or yolo). Re-invoke to change the mode mid-session.
---

# CF Merge Mode Shim

The `SessionStart` hook (`session_start.rb`) states the current merge mode
(falling back to `local-only` when nothing is persisted) on session start,
resume, `/clear`, and compaction. It never asks. The mode is set by one of the
six direct commands below or by `/cf`, persisted per session (a `PostToolUse`
hook records the answer to `~/.claude/cf/sessions/<session_id>/merge-mode`),
and restated every turn by a `UserPromptSubmit` hook, so it survives
compaction. This file is the manual `/cf` picker path plus the rules for
applying the chosen mode.

## /cf

Call `AskUserQuestion` once with two questions, to re-set both the session's
merge mode and its away mode:

**Question 1:** "How should I handle changes from this session?"
**Header:** Merge mode
**Options:**

1. **Local only:** No push, no PR. Changes stay on disk.
2. **Merge ready:** Push branch, open PR, ensure CI is green. You merge manually.
3. **Admin bypass:** Push branch, open PR, squash-merge immediately via admin bypass once CI is green.
4. **Yolo:** Commit and push straight to the target branch (main, or
   whichever branch is in play in a multi-branch flow like
   development/staging/production). Never create a new PR; merging an
   existing PR is still fine.

**Question 2:** "Are you at the keyboard for this session?"
**Header:** Away mode
**Options:**

1. **Active:** Ask normally.
2. **Away:** Do not ask questions; take the recommended or safe default and
   report the assumption.

Acknowledge both choices in one line, then proceed.

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

### The fast path: six direct commands

Each command below sets one axis directly, with no `AskUserQuestion` call, and
is the preferred way to set or change a mode mid-session. `/cf` remains the
manual entry point for setting both axes together.

| Command | Sets |
|---|---|
| `/cf:local-only` | Merge mode to `local-only` |
| `/cf:merge-ready` | Merge mode to `merge-ready` |
| `/cf:admin-bypass` | Merge mode to `admin-bypass` |
| `/cf:yolo` | Merge mode to `yolo` |
| `/cf:away` | Away mode on |
| `/cf:active` | Away mode off |

### Away mode

While away mode is on, `away_restate.rb` reminds every turn not to ask and to
take the recommended or safe default instead, reporting what was assumed.
`away_guard.rb` (`PreToolUse`) enforces this by denying any `AskUserQuestion`
call whose questions do not carry one of three floor headers that still fire
even while away, because their default is destructive or a real secret is at
stake: `Remote delete`, `Untracked`, and `Secret alert`. Running `/cf` itself
is denied while away, since asking both mode questions is a contradiction of
away mode; the deny message points at the six direct commands and at
`/cf:active`.
