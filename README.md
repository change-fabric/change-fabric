# skills

A collection of personal [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skills — reusable prompt shortcuts for common workflows.

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

### `/pst:code-review`

Code review with worktree-isolated fix verification. Every finding is validated by applying the suggested fix in an isolated worktree and running quality gates — findings that break the build are dropped. Supports GitHub PR reviews, local-only output, autonomous auto-fix, and multi-round sweep mode.

```
/pst:code-review 42
/pst:code-review https://github.com/owner/repo/pull/42
/pst:code-review --local
/pst:code-review --autofix
/pst:code-review --sweep
```

### `/pst:qa`

Autonomous QA testing that synthesizes test plans from PR context and code diffs, then executes via browser automation (Playwright MCP or CDP). Auto-judges pass/fail and posts evidence to the PR. Use `--guided` for interactive human-driven testing.

```
/pst:qa 42
/pst:qa https://github.com/owner/repo/pull/42
/pst:qa --guided
/pst:qa --post-merge
```

### `/decide-for-me`

Tells Claude to pick the best approach instead of presenting options. Evaluates simplicity, reliability, scalability, maintainability, and end-user experience.

```
/decide-for-me
```

### `/spec-gen`

Launches an in-depth interview to build a complete implementation spec. Covers technical details, UI/UX, concerns, tradeoffs, and scope — asks non-obvious questions until the spec is ready.

```
/spec-gen
/spec-gen "Add org invitation flow"
```

### `/validate-quality-gates`

Runs build, lint, typecheck, test, and test:coverage in a loop — fixing failures as it goes until all checks pass cleanly.

```
/validate-quality-gates
```

## License

[MIT](LICENSE)
