---
name: cf:refactor
description: Run a behavior-preserving refactor over a PR, branch, repo, file, or glob using all applicable cf rubrics.
---

Question:
What is the smallest change that improves maintainability without changing behavior?

Scope:
- PR
- Branch
- Repository
- File
- Glob

If scope is ambiguous:
- Ask.
- Do not guess.

Workflow:
1. Resolve scope to files.
2. Route files through the applicable cf skills to find refactoring opportunities.
3. For each smell: identify the change risk, apply the smallest refactoring, stop before redesigning.
4. Verify with tests/build.
5. Report changes.

Route files with: `ruby ~/.claude/cf/bin/skill_route.rb <files...>`
