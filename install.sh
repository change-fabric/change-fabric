#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
COMMANDS_DIR="$HOME/.claude/commands"

SKILLS=(
  "decide-for-me"
  "pst:code-review"
  "pst:qa"
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

echo ""
echo "Run /decide-for-me, /pst:code-review, /pst:qa, /spec-gen, or /validate-quality-gates in any Claude Code session."
