---
name: cf:ai-slop
group: rubrics
description: AI slop rubric for code, prose, commits, and PR text. Auto-applied by the cf shim to everything you author; also invocable directly.
auto:
  all_files: true
---

# AI Slop

Would an experienced human write it this way? Plain, concrete, no filler.
- Delete filler, repetition, generic praise, and marketing language.
- Comments explain why, constraints, or tradeoffs; delete ones that restate code.
- Prefer a clearer name over a comment.
- No abstraction or configuration nobody needs yet.
- Preserve behavior.
