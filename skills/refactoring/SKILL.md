---
name: pst:refactoring
description: Fowler refactoring smells and moves. Auto-applied by the pst shim on every code change of any kind; also invocable directly.
auto:
  all_code: true
---

# Fowler Refactoring Cheat Sheet

Source: Martin Fowler, *Refactoring*

Rule: smells are signals, not verdicts. Refactor only to reduce change cost; preserve behavior.

| Smell | Default move |
|---|---|
| Duplicated Code | Extract Function / Pull Up Method |
| Long Function | Extract Function |
| Large Class | Extract Class |
| Long Parameter List | Introduce Parameter Object |
| Divergent Change | Extract Class |
| Shotgun Surgery | Move Function / Inline Class |
| Feature Envy | Move Function |
| Data Clumps | Extract Class / Introduce Parameter Object |
| Primitive Obsession | Replace Primitive with Object |
| Repeated Switches | Replace Conditional with Polymorphism |
| Loops | Replace Loop with Pipeline |
| Lazy Element | Inline Function / Inline Class |
| Speculative Generality | Remove Dead Code / Collapse Hierarchy |
| Temporary Field | Extract Class |
| Message Chains | Hide Delegate |
| Middle Man | Remove Middle Man |
| Insider Trading | Move Function / Hide Delegate |
| Data Class | Encapsulate Record / Move Function |
| Refused Bequest | Replace Subclass with Delegate |
| Comments Explaining Bad Code | Extract Function / Rename Function |

Agent protocol:
1. Name the smell.
2. Name the change risk.
3. Apply the smallest behavior-preserving move.
4. Stop before redesigning.
</content>
