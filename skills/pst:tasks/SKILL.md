---
name: pst:tasks
description: Inspect and manage the session task ledger for multi-repo orchestration. Show what tasks are in flight, mark tasks done or failed, dump a context bundle for new agents, or clear the ledger.
argument-hint: "[done|fail|context|clear] [<id>] [<summary>]"
allowed-tools: Bash
---

# /pst:tasks

Manage the session task ledger (rule 22). All operations are direct Bash calls; do not spawn agents.

## Locate the script

Resolve the ledger script path in one Bash step and export it as LEDGER:

```sh
LEDGER="$(ruby -e "require 'pathname'; puts Pathname.new(File.realpath(File.expand_path('~/.claude/commands/pst.md'))).dirname.join('scripts/pst-ledger.rb')")"
```

If that fails (non-zero exit or empty output), print "pst:tasks: cannot locate pst-ledger.rb" and stop.

## Subcommands

### No args -- show ledger table

1. Run `ruby "$LEDGER" list` and print the output.
2. If tasks exist, append a one-line status summary: count by status (pending, running, done, failed) stated plainly. No hedging.

### `done <id> [summary]`

Run `ruby "$LEDGER" done <id>` (add `--summary "<summary>"` when a summary is provided). Print the command output.

### `fail <id> [summary]`

Run `ruby "$LEDGER" fail <id>` (add `--summary "<summary>"` when a summary is provided). Print the command output.

### `context`

Run `ruby "$LEDGER" context` and print the output. This markdown block is for pasting into new agent prompts as a sibling-task header.

### `clear`

Run `ruby "$LEDGER" clear` and print the confirmation.

## Notes

- Do not invent task IDs or statuses. Report exactly what the ledger returns.
- The ledger is session-scoped; it is initialized automatically when `/pst` arms the session.
