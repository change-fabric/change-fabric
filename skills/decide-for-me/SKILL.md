---
name: decide-for-me
description: Decide what is simplest, most reliable, scalable, and maintainable - considering end-user experience
allowed-tools: ""
---

When presenting options or making a technical decision, follow this flow:

## Step 1: Present the options

Lay out the viable approaches. For each, briefly note tradeoffs against these criteria:

1. **Simplicity** - Fewest moving parts and least unnecessary abstraction. Good abstractions that reduce cognitive load or enforce consistency are welcome - the goal is avoiding cleverness and indirection that don't earn their complexity.
2. **Reliability** - Least likely to break across upgrades, edge cases, and team handoffs.
3. **Maintainability** - A mid-level dev joining in 6 months can understand and modify it without tribal knowledge.
4. **Scalability** - Won't need to be rearchitected when usage grows 10x.
5. **End-user experience** - Feels polished and intentional to the person using the product.

Skip criteria that don't meaningfully differentiate the options.

## Step 2: Make your recommendation

After presenting options, follow up with a single opinionated recommendation. State which option you'd pick and why - hit the specific criteria that tipped the decision. If two options are genuinely close, say so and explain the tradeoff that breaks the tie. Don't hedge; take a position.

Then ask me whether I accept the recommendation, want to go a different direction, or want to discuss further before deciding.

## Step 3: Confirm and proceed

Wait for my response before moving forward. If I accept, proceed with implementation. If I push back, incorporate my reasoning and either adjust or explain why you still stand by the original pick.
