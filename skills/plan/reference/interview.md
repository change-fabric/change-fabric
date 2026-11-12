# The interview

Read this before asking anything. It is the difference between a plan that
records the user's judgment and a plan that records yours wearing their name.

**You run this, not a subagent.** `AskUserQuestion` is not available inside a
subagent; an agent that tries gets an explicit error. Research agents surface
candidates, you ask them.

## What earns a question

A question earns a slot when all three are true:

1. **The answer changes the plan.** Different phases, different files,
   different names, different architecture. If both answers produce the same
   plan, it is not a question.
2. **Evidence cannot settle it.** You already read the repo, the config, the
   existing conventions. What is left is preference, priority, risk appetite,
   naming, scope, or a tradeoff with no objectively right side.
3. **Guessing wrong is expensive.** The executing session would build the
   wrong thing, or the user would have to unwind it.

Cheap tests. Would you defend this decision to the user after the fact without
flinching? Ask. Is the answer written somewhere you have not looked yet? Go
look, do not ask. Is one option clearly right on the evidence? Decide it, and
say in the plan that you decided it and why.

## What does not earn a question

- Anything a `grep` settles. Read first, always.
- Style, formatting, and file layout the repo already fixes by convention.
- "Should I proceed" and "does this look right". Those are check-ins, not
  decisions. Do the work and report.
- Restating something the user already said in the invocation.
- More than four decisions in one call. Batch and prioritize instead.

## Shape of a question

Every question carries your own point of view. You researched it; a bare menu
wastes that. Concretely:

- **header**: 1 to 12 characters, the decision's short name (`Lane name`,
  `Gate default`, `Storage`).
- **question**: the decision at stake, plus the one fact that makes it a real
  fork. Two sentences at most.
- **options**: 2 to 4, each with a `label` and a `description` naming the
  concrete consequence, not the abstraction. Say what changes in the plan.
  Put your recommendation first and open its description with `Recommended:`
  and the reason in one clause.
- **multiSelect**: true only when the answers genuinely compose (which lanes
  to include). A fork is single-select.

The user can always write their own answer instead of picking. Design for
that: a good option set makes their free-form answer sharper, it does not try
to preempt it.

## Rounds

Round one asks the questions that gate the plan's shape: architecture,
naming, scope boundary, what is explicitly out.

Then **re-research against the answers**. Answers move the ground. A user who
picks a different storage layer than you assumed has just invalidated part of
your research, and the questions that matter now did not exist an hour ago.
`SendMessage` the research agent with the ledger and the narrow question the
answers opened.

Round two asks what round one's answers created. Round three exists for the
case where round two's answers did it again. Three rounds is the cap; if you
are still finding shape-changing questions after three, the goal is too big
for one plan, and saying so is more useful than a fourth round.

Stop as soon as a round produces no question that meets the bar. Do not pad a
round to look thorough.

## The ledger

Keep a running record. Each entry:

```
- Decision: <the short name>
  Question asked: <what you put to the user>
  Answer: <their answer, verbatim, including anything they typed freehand>
  Consequence: <what changed in the plan because of it>
```

The ledger goes to the writing agent verbatim and is reproduced in `plan.md`
under `## Decisions (settled, do not re-litigate)`. That section is the
plan's spine: it is what stops the executing session from reopening a call the
user already made, and it is why the user's answer to a naming question
survives into the built code instead of evaporating with this session.

Record what the user rejected too, when they rejected it for a reason. A plan
that says "not X, because the user said Y" is worth more than one that never
mentions X.

## Judge mode (`--judge`)

Only when invoked with `--judge` and the session merge mode is admin-bypass.
Under merge-ready, ignore the flag and run the human interview above.

The bar for what earns a question is unchanged. For each question that
clears it:

1. Spawn 2 to 3 proposer agents in one message (`model: opus`,
   `run_in_background: true`), each with a distinct brief: one favors the
   smallest change, one favors the most robust design, and an optional third
   argues from the repo's existing conventions. Prompt:

   ```
   Decision: {{header}}. Question: {{question}}. Options: {{options}}.
   Research findings: {{findings}}. Your brief: {{brief}}.
   Return JSON {"answer": "...", "rationale": "...", "risk": "..."}.
   Write no files, ask nothing.
   ```

2. Spawn one judge agent (`model: opus`) with every proposal verbatim:

   ```
   Pick or merge one answer for {{header}} from these proposals. Prefer the
   answer that is cheapest to reverse when proposals are close. Return JSON
   {"answer": "...", "rationale": "...", "dissent": "..."}.
   ```

   On a split with no majority the judge still picks, and records the dissent.

3. Record the result in the ledger with the marker line:

   ```
   - Decision: <the short name>
     Question asked: <the question>
     Answer: <judge's answer>
     Answered by: judge
     Dissent: <judge's dissent, or none>
     Consequence: <what changed in the plan>
   ```

The writing agent lists every `Answered by: judge` entry under
`### Judged decisions (unreviewed)` inside the Decisions section, one line
each, and the handoff names them as open to revisiting. Judged decisions are
settled for execution but not for the user: they may reopen any of them.

The step 7b roast uses the same protocol for a contested roast finding under
`--judge`: the ledger entry and the `## Roast` line carry
`Answered by: judge (roast)` instead of `Answered by: judge`, and it is listed
under `### Judged decisions (unreviewed)` the same way.
