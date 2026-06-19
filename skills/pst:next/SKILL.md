---
name: pst:next
description: Survey the current session context and any background agents, then surface one opinionated recommendation of what to do next (320 chars max) via AskUserQuestion. Takes no action until the user confirms.
argument-hint: ""
allowed-tools: Agent, AskUserQuestion, Bash, TaskList
---

# /pst:next

Give one opinionated recommendation of what to do next, grounded in the current session and any running or recently completed background agents. Ask before acting.

## Steps

1. Call TaskList to get the status of any background agents in this session. Also run the following Bash step to get the ledger table:

   ```sh
   LEDGER="$(cat ~/.claude/pst/ledger-path 2>/dev/null)"
   ruby "$LEDGER" list 2>/dev/null || echo "(no tracked tasks)"
   ```

   If the command fails or the ledger is empty, treat the output as "(no tracked tasks)".

2. Spawn a Haiku background agent (`model: haiku`) with:
   - A concise summary of what has happened in the current session (what was built, what was merged, what is still open)
   - The TaskList output
   - The ledger output from step 1
   - The instruction below

   Haiku agent instruction:

   ```
   You are advising an engineering session. Based on the session summary and
   background agent status provided, give ONE opinionated recommendation of
   what to do next. Be specific: name the exact action, skill, or command.
   No hedging, no options, no explanation. Max 320 characters.
   If the ledger shows pending or failed tasks, factor those into the recommendation
   -- they are high-priority candidates for what to do next.

   Session summary:
   {{session_summary}}

   Ledger tasks (multi-repo tracking):
   {{ledger_output}}

   Background agents:
   {{task_list}}
   ```

   Use a structured output schema: `{ "recommendation": "string <= 320 chars" }`.

3. Present the recommendation via `AskUserQuestion` with two options:
   - **Yes, do it** -- proceed with the recommendation immediately
   - **No, skip** -- stop; take no action

4. If yes: execute the recommendation. If no: stop.

## Notes

- The Haiku agent does the synthesis; it is reading existing context, not doing deep analysis, so Haiku is the right tier.
- The 320-character cap is a hard constraint. If the Haiku agent exceeds it, truncate to 320 chars.
- Do not show the recommendation as prose before the AskUserQuestion. The question IS the recommendation.
