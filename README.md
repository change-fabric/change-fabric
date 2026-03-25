# skills

A collection of personal [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skills - reusable prompt shortcuts for common workflows.

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed

## Install

```bash
git clone https://github.com/pstaylor-patrick/skills.git
cd skills
./install.sh
```

This creates symlinks in `~/.claude/commands/` for all skills, making them available in every Claude Code session.

## Uninstall

```bash
./install.sh --uninstall
```

## Skills

### `/pst:auto`

High-autonomy orchestrator that turns rough, unstructured prompts into review-ready pull requests. Asks up to 3 clarifying questions, then runs autonomously through implementation, slop cleanup, quality gates, preflight code review, push/PR creation, QA, and a final autofix review pass. Opens the finished PR in your browser.

```
/pst:auto "add an org invitation flow"
/pst:auto "fix the broken dashboard filtering and get this branch ready for review"
/pst:auto "take this half-finished work and make the PR fully review-ready"
```

### `/pst:next`

Assess the current state of your work and get one opinionated recommendation for the best next step. Reads git state, GitHub PR status, and project context to tell you THE answer, not a menu of options.

```
/pst:next
/pst:next --verbose
/pst:next --why
```

### `/pst:code-review`

Code review with worktree-isolated fix verification. Every finding is validated by applying the suggested fix in an isolated worktree and running quality gates - findings that break the build are dropped. Supports GitHub PR reviews, local-only output, autonomous auto-fix, and multi-round sweep mode.

```
/pst:code-review 42
/pst:code-review https://github.com/owner/repo/pull/42
/pst:code-review --local
/pst:code-review --autofix
/pst:code-review --sweep
```

### `/pst:demo`

Generate a reusable demo/QA runbook from the current feature branch. Analyzes code changes, commits, and PR context to create a step-by-step walkthrough saved as a skill in the target repo's `.agents/skills/` directory. Usable for both QA testing and stakeholder Loom demos.

```
/pst:demo
/pst:demo --update
/pst:demo --dry-run
```

### `/pst:push`

Auto-commit, push the current branch, ensure a PR exists against the default branch, and refresh the PR title and description to reflect all changes on the branch. Then autonomously validate every unchecked test-plan checkbox via terminal commands (build, lint, typecheck, test) and code-level checks -- no browser automation. Posts a validation comment and checks off passing items.

```
/pst:push
/pst:push --dry-run
```

### `/pst:qa`

Autonomous QA testing that synthesizes test plans from PR context and code diffs, then executes via browser automation (Playwright MCP or CDP). Auto-judges pass/fail and posts evidence to the PR. Use `--guided` for interactive human-driven testing.

```
/pst:qa 42
/pst:qa https://github.com/owner/repo/pull/42
/pst:qa --guided
/pst:qa --post-merge
```

### `/pst:react-refactor`

Extract business logic from React/Next.js components into tested custom hooks. Uses [Vercel react-best-practices](https://github.com/vercel-labs/agent-skills) (64+ rules) as the industry baseline, layered with opinionated architecture preferences: hooks in `*.ts` files, comprehensive vitest coverage, zero `eslint-disable`, named exports only.

```
/pst:react-refactor src/components/Dashboard.tsx
/pst:react-refactor --all
/pst:react-refactor --branch feature/new-dashboard
/pst:react-refactor --dry-run
```

Vercel react-best-practices (64+ industry rules) is installed automatically by `./install.sh` via the skills CLI. The skill degrades gracefully if the external dependency is missing.

### `/pst:slop`

Scan for and remove common AI-generated slop from your branch changes (default) or the entire repo (`--repo`). Detects em dashes, excessive documentation, disabled quality gates, band-aid exclusions, over-complicated abstractions, dead code, error theater, and type safety escapes. Interactive by default - presents findings and asks before fixing.

```
/pst:slop
/pst:slop --repo
/pst:slop --dry-run
/pst:slop --auto
```

### `/decide-for-me`

Tells Claude to pick the best approach instead of presenting options. Evaluates simplicity, reliability, scalability, maintainability, and end-user experience.

```
/decide-for-me
```

### `/spec-gen`

Launches an in-depth interview to build a complete implementation spec. Covers technical details, UI/UX, concerns, tradeoffs, and scope - asks non-obvious questions until the spec is ready.

```
/spec-gen
/spec-gen "Add org invitation flow"
```

### `/validate-quality-gates`

Runs build, lint, typecheck, test, and test:coverage in a loop - fixing failures as it goes until all checks pass cleanly.

```
/validate-quality-gates
```

## License

[MIT](LICENSE)
