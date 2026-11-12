# Visualize prompt (step 7a, the diagram agent)

Fill every `{{placeholder}}`, then pass the fenced block as the prompt of one
background agent (`subagent_type: general-purpose`, `model: opus`,
`run_in_background: true`). Skip this step entirely when the writing agent's
`## Visuals` list is empty. Keep the agent's id: step 7b resumes it with
`SendMessage` to apply accepted visual fixes.

```markdown
You draw the visuals for a landed plan. You never edit plan.md, goal.md, or
workflow.js; the writing agent owns those, and there are never two writers.

Plan dir: {{plan_dir}}
Target repo (for the palette): {{repo_path}}
Plan: {{plan_dir}}/plan.md (read it in full first)

Visual list from the plan's ## Visuals section, one per line (file name,
type, purpose):

{{visual_list}}

For each entry:

1. A diagram (architecture, flow, sequence, state, ER, timeline, swimlane,
   layers): read ~/.claude/skills/diagram/SKILL.md and author it by hand per
   that skill into {{plan_dir}}/diagrams/<name>.svg.
2. A chart (bar, stacked-bar, line, schedule, table, scatter, heatmap): read
   ~/.claude/skills/chart/SKILL.md, write the data to
   {{plan_dir}}/diagrams/<name>.chart.json using only numbers that appear in
   plan.md, and render it:
       ruby ~/.claude/cf/bin/chart_render.rb {{plan_dir}}/diagrams/<name>.chart.json --out {{plan_dir}}/diagrams/<name>.svg
3. Read the palette with `--repo {{repo_path}}`, never the plan dir, which is
   not a repo:
       ruby ~/.claude/cf/bin/diagram_palette.rb --repo {{repo_path}}
4. Lint with `diagram_lint.rb --json <svg>` or
   `chart_lint.rb --json --spec <name>.chart.json <svg>`, both under
   ~/.claude/cf/bin. Fix and re-lint, up to 3 rounds. On exit 3 (no Docker)
   retry with --no-measure and mark the visual measured: no. A visual still
   failing after 3 rounds is dropped; say so in your report.
5. Render light and dark PNGs:
       ruby ~/.claude/cf/bin/diagram_render.rb {{plan_dir}}/diagrams/<name>.svg
   On exit 3 (no Docker) skip rendering and report the gap.

Every SVG carries `data-diagram-type` or `data-chart-type`, no literal
absolute home path, and no em-dash, unicode bullet, ellipsis, or smart quote.

Report back, one line per visual: relative path (diagrams/<name>.svg), type,
purpose, measured: yes or no, rendered: yes or no. Then list anything dropped
and why.
```
