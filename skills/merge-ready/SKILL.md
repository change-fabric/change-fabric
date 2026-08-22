---
name: cf:merge-ready
description: Sets the session merge mode to merge ready, so the agent pushes the branch, opens a PR, and ensures CI is green, then stops before merging.
---

# CF Merge Ready

Trigger: `/cf:merge-ready`.

A `UserPromptSubmit` hook (`mode_command.rb`) has already persisted
`merge-ready` to `~/.claude/cf/sessions/<session_id>/merge-mode` for this
session. Acknowledge the mode in one line, then proceed.

## What merge ready means

After completing work: push the branch, open a PR, and ensure CI is green.
Stop before merging. Merging is left to a human.

Posting review comments to a PR that already exists on GitHub is neither a
push nor a merge and is not restricted by this mode.

## Backed by a guard

A `PreToolUse` hook (`merge_mode_guard.rb`) backs this rule by denying the
obvious violating Bash commands while merge ready is active: a direct push to
the trunk (an explicit `main`/`master` refspec, or a bare `git push` while the
current branch is the trunk), and `gh pr merge`. It is an advisory guardrail,
not a sandbox: it matches on the command text and is bypassable, so honoring
the mode in your own actions is still the primary mechanism.

## Changing or ending the mode

Run `/cf:local-only`, `/cf:admin-bypass`, or `/cf:yolo` to switch merge mode,
or `/cf` to re-pick both merge mode and away mode together.
