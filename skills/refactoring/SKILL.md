---
name: cf:refactoring
group: rubrics
description: Fowler refactoring smells and moves, removal first. Auto-applied by the cf shim on every code change; also invocable directly.
auto:
  all_code: true
---

# Refactoring

Question: what does the next change cost here, and does this move make it cheaper?

Removal moves come first.

| Smell | Move |
|---|---|
| Lazy Element | Inline Function / Inline Class |
| Speculative Generality | Collapse Hierarchy, delete the unused parameter, hook, or option |
| Middle Man | Remove Middle Man |
| Dead Code | Delete it |
| Duplicated Code | Extract Function, only per the extract rule below |
| Long Function | Extract Function |
| Large Class, Divergent Change | Extract Class |
| Long Parameter List, Data Clumps | Introduce Parameter Object |
| Feature Envy, Shotgun Surgery | Move Function |
| Repeated Switches | Replace Conditional with Polymorphism |
| Message Chains | Hide Delegate |
| Primitive Obsession | Replace Primitive with Object |

Extract rule: extract only when a second caller exists now or the change touches
the duplicate. Duplication beats a wrong abstraction. A single-implementation
interface, factory, or registry is Speculative Generality.

Design guards:
- One reason to change per class; tell, do not ask.
- Few collaborators and no deep chains (Law of Demeter).
- Prefer composition to inheritance; inject collaborators.
- No new config, flag, or dependency the task did not ask for.

Each finding names the smell, the move, and the change it makes cheaper, or says
none. Apply the smallest behavior-preserving move, then stop.
