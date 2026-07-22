---
name: cf:ai-slop
description: AI slop rubric. Auto-applied by the cf shim to everything you author (code, prose, commit messages, branch names, PR titles and descriptions); also invocable directly.
auto:
  all_files: true
---

# AI Slop Rubric

Applies to everything you author: source code, prose and documentation, commit
messages, branch names, and pull request titles and descriptions.

Question: Would an experienced human write it this way?

Prefer:
- plain language
- concrete statements
- self-documenting code
- direct structure
- necessary abstraction only

Remove:
- filler
- repetition
- obvious comments
- unnecessary abstraction
- unnecessary configuration
- generic praise
- marketing language
- agent attribution footers (the "Generated with" / "Claude Code" line some harnesses append to commits and PRs)

Punctuation (no AI-slop glyphs; en-dash is fine):
- no em-dash: use a spaced hyphen ' - ' or restructure
- no bullet glyph: use '*' or '-' for lists
- no ellipsis glyph: use '...'
- no smart quotes: use straight ' and "

Comments:
- explain why
- explain constraints
- explain tradeoffs
- do not narrate code

Agent protocol:
1. Delete filler.
2. Replace vague with specific.
3. Remove comments that restate code.
4. Prefer clearer names over more comments.
5. Preserve behavior.
