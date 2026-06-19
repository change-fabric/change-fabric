---
name: pst:now
description: Snapshot what every active agent and initiative in this session is focused on right now -- current goal, active agents, in-flight work -- as a 320-char executive summary plus a flat bullet list.
argument-hint: ""
allowed-tools: Agent, Bash, TaskList
---

# /pst:now

Produce a present-tense snapshot of the session: what is the current goal, and what is each agent doing right now? No forward-looking recommendations -- that is `/pst:next`. This is a status read of the active moment.

## Steps

1. Call `TaskList` to get all background agents and their current status. Also run the following Bash step to get the ledger table:

   ```sh
   LEDGER="$(cat ~/.claude/pst/ledger-path 2>/dev/null)"
   ruby "$LEDGER" list 2>/dev/null || echo "(no tracked tasks)"
   ```

   If the command fails or the ledger is empty, treat the output as "(no tracked tasks)".

2. Spawn a Haiku background agent (`model: haiku`, `effort: low`) with:
   - A concise description of the current session context (what the user is working on, what was most recently said or requested, what is still open)
   - The `TaskList` output
   - The ledger output from step 1
   - The instruction below

   Haiku agent instruction:

   ```
   You are producing a present-tense status snapshot for an engineering session.
   Answer: what is this session focused on RIGHT NOW?

   Rules:
   - Top line: one executive summary of the current goal and state, max 320 characters.
   - Then: a flat bullet list, one entry per active agent or initiative.
   - Each bullet: max 120 characters. No sub-bullets.
   - Tense: present only. No past recap, no future recommendations.
   - Omit completed or idle agents unless they are blocking something active.
   - If the ledger has tasks, include their statuses in the bullets (one bullet per active ledger task if there are few, or a rolled-up count by status if there are many).
   - No hedging, no filler.

   Session context:
   {{session_context}}

   Ledger tasks (multi-repo tracking):
   {{ledger_output}}

   Active agents (TaskList output):
   {{task_list}}
   ```

   Use a structured output schema:

   ```json
   {
     "summary": "string <= 320 chars",
     "bullets": ["string <= 120 chars"]
   }
   ```

3. Output the result directly as text -- no AskUserQuestion gate needed. Format as:

   ```
   <summary>

   - <bullet>
   - <bullet>
   ```

4. If there are no active agents and no clear current goal, the summary should say so plainly (e.g. "Session is idle -- no agents running, no goal in flight.").

## Notes

- Haiku is the right tier: this is context compression, not reasoning.
- Hard caps: summary <= 320 chars, each bullet <= 120 chars. Truncate if the agent exceeds them.
- `/pst:now` = what is happening now. `/pst:next` = what to do next. Keep them distinct.
- Do not list skills or tools as "agents" unless they are actively running as background tasks.
