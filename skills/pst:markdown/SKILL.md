---
name: pst:markdown
description: Generate a markdown report or summary from the latest response, copied to clipboard
argument-hint: "[--slack]"
allowed-tools: Bash
---

# Markdown Clipboard Export

Re-render or summarize the most recent substantive response as clean markdown text and copy it to the clipboard.

---

## Input

<arguments> #$ARGUMENTS </arguments>

**Parse arguments:** Check if `--slack` flag is present.

---

## Formatting Rules (always applied)

- Use `*` (asterisk) for bullet list items - never `-` (hyphen)
- Use 4 spaces for nested indentation
- Never use em dashes - replace every occurrence with a regular hyphen-minus (`-`) or rephrase
- Clean, readable markdown structure

---

## Default Mode (no flag)

- Standard markdown bold: `**bold**` (double asterisk)
- Tables are fine
- Standard markdown headings, code blocks, links, etc.

---

## Slack Mode (`--slack`)

- Bold uses single asterisk: `*bold*` instead of `**bold**`
- Prefer lists over tables - tables do not render well in Slack
- Convert any tabular data into labeled list items instead

---

## Execution

**Step 1 - Render.** Look back at the most recent substantive response in the conversation (before this skill was invoked). Re-render or summarize that content as clean markdown, applying the formatting rules above and the mode-specific rules.

**Step 2 - Copy to clipboard.** Pipe the final markdown to `pbcopy` using the Bash tool:

```bash
cat <<'MARKDOWN' | pbcopy
{rendered markdown here}
MARKDOWN
```

**Step 3 - Confirm.** Print a short confirmation that the content was copied, noting which format was used (standard markdown or Slack markdown).
