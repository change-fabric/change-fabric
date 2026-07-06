# pst:code-review posting reference

Read this before step 4 (posting any comment). It has no bearing on steps 1-3.

## Priority

Assign a tier from what the Verify stage actually proved, never from how
severe it sounds:

| Tier | Bar | Requires |
|---|---|---|
| P1 (red) | Confirmed break: crash, wrong output, security hole, data loss | A reproduction, plus Recheck P1 agreement |
| P2 (yellow) | Confirmed but bounded: real bug/smell needing specific input, config, or scale; or a refactor with verified payoff | A reproduction from Verify |
| P3 (green) | Real but low blast radius, and only worth interrupting for because the fix is a one-line, unambiguous diff | A reproduction from Verify, and a suggestion block (see below) |

Drop anything that only clears the P3 bar and has no suggestion block; it is
noise, not feedback. Every posted finding needs a `title` (written by the
Verify stage in workflow.js); render the comment body via `ruby
~/.claude/pst/bin/render_finding_comment.rb`, never a hand-written tier
prefix.

## Posting style

One finding, one comment: an emoji-badged tier header (`🔴 P1`, `🟠 P2`,
`🟢 P3`) and title on line 1, then the concrete failure scenario, then the
fix. Before calling `add_comment_to_pending_review`, pipe the finding as
JSON (`{tier, title, scenario, suggestion}`, `scenario` carrying the
evidence-backed detail) to `ruby ~/.claude/pst/bin/render_finding_comment.rb`
on stdin and post its stdout verbatim as the comment body. The script owns
the template, the badge, and the char-budget fallback (drop the suggestion
block, then truncate the scenario) once the finding is over its 640-char
cap; do the prose-trimming judgment call yourself first so the script's
truncation is a safety net, not the first line of defense. No summary of
the summary, no praise, no restating the diff. Apply `pst:ai-slop`'s
punctuation and tone rules to `title` and `scenario` before rendering.

Add a GitHub suggestion block only when the fix is mechanical and
unambiguous from the finding alone (a rename, a null check, an off-by-one,
a dead branch, the exact rubric move a matched skill names) and touches
only the lines already in the diff. Never suggest a diff for anything
needing a judgment call, multiple files, or unclear intent; omit
`suggestion` from the finding instead.
