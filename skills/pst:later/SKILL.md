---
name: pst:later
description: Run /pst:now and /pst:next in parallel, then use an Opus background agent to reason about second-order consequences and surface the next 3-5 roadmap stages beyond the immediate next step -- 320-char exec summary plus 1-5 opinionated bullets (160 chars max each).
argument-hint: ""
allowed-tools: Agent, Bash, Skill, TaskList
---

# /pst:later

Answer the question: after what we are doing right now and what we do next, what comes after that? This is the roadmap horizon view -- second-order consequences and the 3-5 stages that will need to happen to carry the current work through to completion.

## Steps

1. Call `TaskList` to get background agent status.

2. Invoke `/pst:now` and `/pst:next` in parallel (via two background Haiku agents or by calling the skills directly). Collect both outputs. Also run the following Bash step to dump the full ledger JSON:

   ```sh
   LEDGER="$(cat ~/.claude/pst/ledger-path 2>/dev/null)"
   ruby "$LEDGER" dump 2>/dev/null || echo "[]"
   ```

   If the command fails, treat the ledger JSON as `[]`.

3. Spawn an Opus background agent (`model: opus`, `effort: high`) with:
   - The session context (current project, goal, recent decisions)
   - The `/pst:now` snapshot (what is active right now)
   - The `/pst:next` recommendation (the immediate next action)
   - The full ledger JSON from step 2
   - The instruction below

   Opus agent instruction:

   ```
   You are a senior engineering advisor performing second-order consequence
   analysis for an active engineering session.

   You have:
   - A snapshot of what is happening right now (/pst:now output)
   - The immediate next recommended action (/pst:next output)
   - The full task ledger (JSON) for this session

   Your task: reason about what comes AFTER the immediate next step.
   Consider second-order consequences: what will the next action unlock,
   block, or require? What are the 3-5 stages on the roadmap that follow?
   The full task ledger is provided. Use the mix of pending, running, done,
   and failed entries to identify gaps and surface them in the roadmap.

   Rules:
   - Top line: 320-char exec summary of the roadmap horizon (not what is
     happening now, not what is next -- what comes AFTER next).
   - Then: 1-5 opinionated bullets, each a specific recommended action to
     take later, in rough priority order.
   - Each bullet: max 160 characters. No sub-bullets.
   - Be opinionated. Name specific skills, commands, or decisions.
   - No hedging. No recap of /pst:now or /pst:next.

   Current session context:
   {{session_context}}

   /pst:now output:
   {{now_output}}

   /pst:next output:
   {{next_output}}

   Full task ledger (JSON):
   {{ledger_json}}
   ```

   Use a structured output schema:

   ```json
   {
     "summary": "string <= 320 chars",
     "bullets": ["string <= 160 chars"]
   }
   ```

4. Output the result directly as text. Format as:

   ```
   <summary>

   - <bullet>
   - <bullet>
   ```

5. Hard caps: summary <= 320 chars, each bullet <= 160 chars, 1-5 bullets. Truncate if the Opus agent exceeds them.

## Notes

- Opus is correct here: this is genuine multi-step consequence reasoning, not compression. Haiku/Sonnet will produce shallow roadmaps.
- `/pst:now` = what is happening now. `/pst:next` = immediate next action. `/pst:later` = what follows after that.
- If the session is idle with no clear project context, the summary should say so and the bullets should suggest orienting steps.
- Do not gate on AskUserQuestion -- output directly, same as `/pst:now`.
