# Maintainability Review Doctrine (Fowler-Inspired)

## Purpose

This doctrine provides a maintainability-focused review framework derived from the principles found in Martin Fowler's _Refactoring_ catalogs, Thoughtworks engineering practices, and related software design literature.

It is not a verbatim reproduction of Fowler's published work.

Instead, it synthesizes Fowler's code smells, refactorings, and design philosophy into a practical rubric that can be used by human reviewers and AI coding agents when evaluating code quality.

---

# Core Principle

The primary question during review is:

> How difficult will this code be for another competent engineer to safely understand, modify, test, and extend six months from now?

Code is typically read far more often than it is written.

Future maintainers are therefore a primary stakeholder in every implementation decision.

---

# Fundamental Assumption

Refactoring assumes that correctness already exists.

A refactoring is a behavior-preserving transformation that improves the internal structure of code.

The goal is not to change what the software does.

The goal is to improve how easily humans can understand and evolve the software while preserving existing behavior.

---

# Primary Design Goal

The most important maintainability objective is: minimize the cost of future change.

Most of Fowler's catalog can be viewed through the lens of locality of change.

Healthy systems allow business changes to be implemented in a small number of obvious locations.

Unhealthy systems scatter knowledge across many files, modules, classes, or functions.

---

# Canonical Code Smells

The following smells come from Martin Fowler's code smell catalog (primarily _Refactoring, 2nd Edition_).

These are not bugs. They are indicators that design quality may be degrading.

---

## 1. Duplicated Code

**Signal:** The same behavior exists in multiple locations.

**Risk:** Future changes must be applied repeatedly. Behavior may drift over time.

**Refactorings:** Extract Function, Extract Class, Consolidate Duplicate Logic.

---

## 2. Long Function

**Signal:** A function performs multiple conceptual tasks.

**Risk:** Readers must maintain excessive context. Intent becomes harder to understand.

**Refactorings:** Extract Function, Split Phase, Decompose Conditional.

---

## 3. Large Class

**Signal:** A class accumulates multiple responsibilities.

**Risk:** Changes become coupled. The class becomes difficult to understand and test.

**Refactorings:** Extract Class, Extract Subclass, Extract Superclass.

---

## 4. Feature Envy

**Signal:** Behavior appears more interested in another object's data than its own.

**Risk:** Knowledge lives in the wrong location. Cohesion decreases.

**Refactorings:** Move Function, Move Field.

---

## 5. Primitive Obsession

**Signal:** Business concepts are represented using primitive values instead of domain objects.

**Risk:** Business rules become duplicated. Domain concepts remain implicit.

**Refactorings:** Replace Primitive with Object, Encapsulate Record.

---

## 6. Data Clumps

**Signal:** The same group of values repeatedly appears together.

**Risk:** A domain concept exists but has not been modeled.

**Refactorings:** Introduce Parameter Object, Extract Class.

---

## 7. Long Parameter List

**Signal:** Functions require many inputs.

**Risk:** Call sites become difficult to understand.

**Refactorings:** Introduce Parameter Object, Preserve Whole Object.

---

## 8. Divergent Change

**Signal:** One module changes for many unrelated business reasons.

**Risk:** Responsibilities are mixed together.

**Refactorings:** Extract Class, Move Function.

---

## 9. Shotgun Surgery

**Signal:** One business change requires edits in many locations.

**Risk:** Changes become expensive and error-prone.

**Refactorings:** Move Function, Extract Class, Consolidate Responsibilities.

---

## 10. Repeated Switches

**Signal:** The same branching logic appears throughout the system.

**Risk:** New cases require modifications everywhere.

**Refactorings:** Replace Conditional with Polymorphism, Introduce Strategy.

---

## 11. Message Chains

**Signal:** Code repeatedly navigates deep object graphs.

**Risk:** Coupling increases. Implementation details leak across boundaries.

**Refactorings:** Hide Delegate, Move Function.

---

## 12. Middle Man

**Signal:** A layer primarily forwards calls without adding meaningful behavior.

**Risk:** Complexity increases without corresponding value.

**Refactorings:** Remove Middle Man.

---

## 13. Mutable Data

**Signal:** State changes frequently and unpredictably.

**Risk:** Side effects become harder to reason about.

**Refactorings:** Encapsulate Variable, Separate Query from Modifier.

---

## 14. Global Data

**Signal:** State can be modified from many locations.

**Risk:** Dependencies become invisible.

**Refactorings:** Encapsulate Variable, Dependency Injection.

---

## 15. Speculative Generality

**Signal:** Abstractions exist for hypothetical future requirements.

**Risk:** Complexity exists without delivering present value.

**Refactorings:** Collapse Hierarchy, Inline Class, Remove Unused Abstractions.

---

## 16. Lazy Element

**Signal:** An abstraction contributes little meaningful behavior.

**Risk:** Maintenance cost exceeds value.

**Refactorings:** Inline Class, Inline Function.

---

# Maintainability Outcomes

When evaluating or proposing changes, optimize for these outcomes.

**Higher Cohesion:** Related behavior should live together. A module should have a clear and focused responsibility.

**Lower Coupling:** Modules should know as little as possible about each other's internals.

**Explicit Intent:** Names and structure should communicate purpose clearly. Code should explain itself through design rather than comments.

**Locality of Change:** Business changes should require modifications in the smallest possible number of places.

**Reduced Cognitive Load:** Engineers should be able to understand a component without simultaneously understanding unrelated concerns.

**Strong Domain Modeling:** Business concepts should be represented explicitly rather than hidden inside primitives, conditionals, or conventions.

---

# Review Questions

## Understanding

- Is the intent obvious?
- Is the responsibility obvious?
- Does the naming clearly communicate purpose?
- Can a new engineer understand this quickly?

## Ownership

- Does behavior live near the data it operates on?
- Is knowledge located in the most appropriate module?

## Changeability

- Would a business change require edits in multiple places?
- Is knowledge duplicated?
- Are responsibilities scattered?

## Abstraction Quality

- Does every abstraction justify its existence?
- Is there accidental complexity?
- Is there speculative generality?

## Domain Modeling

- Are important business concepts represented explicitly?
- Are primitives being used where domain objects should exist?

---

# Preferred Decision Rule

When multiple implementations are technically correct, prefer the implementation that minimizes future maintenance cost while maximizing clarity, locality of change, and ease of understanding.

---

# Summary

A maintainable system exhibits clear intent, strong cohesion, low coupling, explicit domain modeling, localized change, minimal duplication, and low cognitive overhead.

The central question is not: "Does this code work?"

The central question is: "How easily can this code continue to work as the business evolves?"
