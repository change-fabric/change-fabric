#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_COMMANDS_DIR="$HOME/.claude/commands"
CODEX_SKILLS_DIR="$HOME/.codex/skills"

SKILLS=(
  "decide-for-me"
  "pst:auto"
  "pst:code-review"
  "pst:demo"
  "pst:figma"
  "pst:markdown"
  "pst:next"
  "pst:push"
  "pst:qa"
  "pst:react-refactor"
  "pst:slop"
  "spec-gen"
  "validate-quality-gates"
)

# Old names that may exist as orphaned symlinks
OLD_SKILLS=(
  "pst-code-review"
  "pst-qa"
)

# ── Uninstall ────────────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
  for skill in "${SKILLS[@]}" "${OLD_SKILLS[@]}"; do
    claude_dst="$CLAUDE_COMMANDS_DIR/$skill.md"
    if [[ -L "$claude_dst" ]]; then
      rm "$claude_dst"
      echo "Uninstalled /$skill from Claude Code (removed $claude_dst)"
    fi

    codex_dst="$CODEX_SKILLS_DIR/$skill"
    if [[ -L "$codex_dst" ]]; then
      rm "$codex_dst"
      echo "Uninstalled /$skill from Codex (removed $codex_dst)"
    fi
  done
  exit 0
fi

# ── Detect available CLIs ────────────────────────────────────────────
mkdir -p "$CLAUDE_COMMANDS_DIR"

CODEX_AVAILABLE=false
if [[ -d "$HOME/.codex" ]]; then
  mkdir -p "$CODEX_SKILLS_DIR"
  CODEX_AVAILABLE=true
fi

# ── Clean up orphaned symlinks ───────────────────────────────────────
for old in "${OLD_SKILLS[@]}"; do
  claude_dst="$CLAUDE_COMMANDS_DIR/$old.md"
  if [[ -L "$claude_dst" ]]; then
    rm "$claude_dst"
    echo "Removed orphaned /$old -> $claude_dst"
  fi

  if [[ "$CODEX_AVAILABLE" == true ]]; then
    codex_dst="$CODEX_SKILLS_DIR/$old"
    if [[ -L "$codex_dst" ]]; then
      rm "$codex_dst"
      echo "Removed orphaned /$old -> $codex_dst (Codex)"
    fi
  fi
done

# ── Install skills ───────────────────────────────────────────────────
for skill in "${SKILLS[@]}"; do
  # Claude Code: file symlink to SKILL.md
  claude_src="$REPO_DIR/skills/$skill/SKILL.md"
  claude_dst="$CLAUDE_COMMANDS_DIR/$skill.md"
  ln -sfn "$claude_src" "$claude_dst"
  echo "Installed /$skill -> $claude_src"

  # Codex: directory symlink to skill folder (includes scripts/ etc.)
  if [[ "$CODEX_AVAILABLE" == true ]]; then
    codex_src="$REPO_DIR/skills/$skill"
    codex_dst="$CODEX_SKILLS_DIR/$skill"
    ln -sfn "$codex_src" "$codex_dst"
    echo "Installed /$skill -> $codex_src (Codex)"
  fi
done

# ── External skill dependencies ──────────────────────────────────────
# pst:react-refactor layers on Vercel's react-best-practices.
# pst:figma layers on Figma's implement-design.
# Install globally so every project gets the latest industry rules.
# NOTE: These are Claude Code-specific via `npx skills add -g`.

EXTERNAL_SKILLS=(
  "vercel-labs/agent-skills --skill vercel-react-best-practices"
  "https://github.com/figma/mcp-server-guide --skill figma-implement-design"
)

if command -v npx &>/dev/null; then
  for ext in "${EXTERNAL_SKILLS[@]}"; do
    echo ""
    echo "Installing external dependency: $ext"
    # shellcheck disable=SC2086
    npx -y skills add $ext -g -y 2>&1 | sed 's/^/  /'
  done
else
  echo ""
  echo "WARNING: npx not found - skipping external skill dependencies."
  echo "         Install Node.js and run ./install.sh again to get Vercel react-best-practices."
fi

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo "Skills installed for Claude Code (${#SKILLS[@]} skills -> ~/.claude/commands/)"
if [[ "$CODEX_AVAILABLE" == true ]]; then
  echo "Skills installed for OpenAI Codex  (${#SKILLS[@]} skills -> ~/.codex/skills/)"
else
  echo "Codex CLI not detected (~/.codex/ not found) -- skipping Codex install."
  echo "Re-run ./install.sh after installing Codex to enable."
fi
echo ""
echo "Available: /decide-for-me, /pst:auto, /pst:code-review, /pst:demo, /pst:figma, /pst:markdown, /pst:next, /pst:push, /pst:qa, /pst:react-refactor, /pst:slop, /spec-gen, /validate-quality-gates"
