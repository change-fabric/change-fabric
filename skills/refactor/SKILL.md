---
name: pst:refactor
description: Run a comprehensive, behavior-preserving refactor over a scope you name (a PR, a branch, the whole repo, a file, or a glob). Routes each file through the pst skills that apply and reports what changed.
---

# /pst:refactor

The verb to `pst:refactoring`'s noun. `pst:refactoring` is the cheat sheet to
understand; this command does the work over a concrete changeset, reusing the
shim's own file-to-skill routing so one deliberate pass applies the same
rubrics the per-edit hooks would.

## 1. Establish scope

Take the scope from the prompt. It is one of:

- **Pull request** - a PR number or URL.
- **Branch** - a feature branch, compared against the default branch.
- **Repository** - every tracked file.
- **File** - a single path.
- **Glob** - a path pattern.

If the prompt names no scope, or the scope is ambiguous, call `AskUserQuestion`
to pin it down before touching anything. Do not guess.

## 2. Resolve scope to a file list

| Scope | Command |
|---|---|
| Pull request | `gh pr diff <n> --name-only` |
| Branch | `git diff --name-only $(git merge-base HEAD <base>)...<branch>` |
| Repository | `git ls-files` |
| File | the path as given |
| Glob | expand the pattern |

Drop paths that no longer exist; a deleted file has nothing to refactor.

## 3. Route files to the skills that cover them

Run the shim's router over the file list:

```
ruby ~/.claude/pst/bin/skill_route.rb <files...>
```

It prints each applicable pst skill and the files it covers, using the same
match rules (`extensions`, `basenames`, `all_code`, `all_files`) the per-edit
hooks use. `pst:ai-slop` covers every file; `pst:refactoring` covers every code
file; the language skills cover their own. Read each named skill's `SKILL.md`
for its rubric before applying it.

## 4. Refactor

Work file by file. For each file, apply the rubrics of the skills that cover it.
Follow the refactoring protocol: name the smell, name the change risk, apply the
smallest behavior-preserving move, stop before redesigning. This is refactoring,
not a rewrite - preserve behavior throughout.

## 5. Verify and report

Run the project's tests or build if present. Report, per file, which skills you
applied and the moves you made. Honor the session merge mode for any push or PR.
