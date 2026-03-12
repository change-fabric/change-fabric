#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
COMMANDS_DIR="$HOME/.claude/commands"

SKILLS=(
  "decide-for-me"
  "spec-gen"
  "validate-quality-gates"
)

if [[ "${1:-}" == "--uninstall" ]]; then
  for skill in "${SKILLS[@]}"; do
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

for skill in "${SKILLS[@]}"; do
  src="$REPO_DIR/skills/$skill/SKILL.md"
  dst="$COMMANDS_DIR/$skill.md"
  ln -sfn "$src" "$dst"
  echo "Installed /$skill → $src"
done

echo ""
echo "Run /decide-for-me, /spec-gen, or /validate-quality-gates in any Claude Code session."
