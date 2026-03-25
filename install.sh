#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
COMMANDS_DIR="$HOME/.claude/commands"

SKILLS=(
  "decide-for-me"
  "pst:code-review"
  "pst:figma"
  "pst:markdown"
  "pst:qa"
  "pst:react-refactor"
  "spec-gen"
  "validate-quality-gates"
)

# Old names that may exist as orphaned symlinks
OLD_SKILLS=(
  "pst-code-review"
  "pst-qa"
)

if [[ "${1:-}" == "--uninstall" ]]; then
  for skill in "${SKILLS[@]}" "${OLD_SKILLS[@]}"; do
    dst="$COMMANDS_DIR/$skill.md"
    if [[ -L "$dst" ]]; then
      rm "$dst"
      echo "Uninstalled /$skill (removed $dst)"
    else
      echo "Nothing to uninstall — $dst not found."
    fi
  done
  exit 0
fi

mkdir -p "$COMMANDS_DIR"

# Remove old hyphenated symlinks if they exist
for old in "${OLD_SKILLS[@]}"; do
  dst="$COMMANDS_DIR/$old.md"
  if [[ -L "$dst" ]]; then
    rm "$dst"
    echo "Removed orphaned /$old → $dst"
  fi
done

for skill in "${SKILLS[@]}"; do
  src="$REPO_DIR/skills/$skill/SKILL.md"
  dst="$COMMANDS_DIR/$skill.md"
  ln -sfn "$src" "$dst"
  echo "Installed /$skill → $src"
done

# ── External skill dependencies ──────────────────────────────────────
# pst:react-refactor layers on Vercel's react-best-practices.
# pst:figma layers on Figma's implement-design.
# Install globally so every project gets the latest industry rules.

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
  echo "WARNING: npx not found — skipping external skill dependencies."
  echo "         Install Node.js and run ./install.sh again to get Vercel react-best-practices."
fi

echo ""
echo "Run /decide-for-me, /pst:code-review, /pst:figma, /pst:markdown, /pst:qa, /pst:react-refactor, /spec-gen, or /validate-quality-gates in any Claude Code session."
