---
name: pst:ruby
description: Sandi Metz POODR design principles. Auto-applied by the pst shim on every Ruby change; also invocable directly.
auto:
  extensions: [rb, rake, gemspec, ru]
  basenames: [Rakefile, Gemfile, Guardfile]
  detect: [Gemfile, "*.gemspec", .ruby-version, Rakefile]
---

# Ruby Design Cheat Sheet

Source: Sandi Metz, *Practical Object-Oriented Design in Ruby (POODR)*

Primary question:
Is this code easy to change?

| Principle | Look for |
|------------|-----------|
| Single Responsibility | One reason to change per class |
| Small Methods | One thing, one level of abstraction |
| Behavior over Data | Tell, don't ask |
| Low Coupling | Few dependencies, no deep chains |
| High Cohesion | Related behavior stays together |
| Small Public API | Minimize public methods |
| Law of Demeter | Talk only to immediate collaborators |
| Composition > Inheritance | Prefer objects over hierarchies |
| Depend on Abstractions | Inject collaborators |
| Duplication > Wrong Abstraction | Avoid premature DRY |

Red flags:
- Large classes
- Large methods
- Feature envy
- God objects
- Message chains
- Global state
- Scattered conditionals
- Premature abstractions

Agent protocol:
1. Identify the change obstacle.
2. Reduce coupling.
3. Increase cohesion.
4. Move behavior to the owning object.
5. Prefer the smallest design improvement.
6. Preserve behavior.
</content>
</invoke>
