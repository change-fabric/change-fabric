#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_COMMANDS_DIR="$HOME/.claude/commands"
PI_HOME_SET=false
if [[ -n "${PI_HOME:-}" ]]; then
  PI_HOME_SET=true
fi
PI_HOME="${PI_HOME:-$HOME/.pi/agent}"
PI_SKILLS_DIR="$PI_HOME/skills"
CODEX_HOME_SET=false
if [[ -n "${CODEX_HOME:-}" ]]; then
  CODEX_HOME_SET=true
fi
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_SKILLS_DIR="$CODEX_HOME/skills"
WANTS_CLAUDE=false
WANTS_CODEX=false
WANTS_PI=false
UNINSTALL=false

SKILLS=(
  "decide-for-me"
  "pst:auto"
  "pst:claude-md"
  "pst:code-review"
  "pst:demo"
  "pst:figma"
  "pst:ingest-pdf"
  "pst:markdown"
  "pst:next"
  "pst:patch"
  "pst:push"
  "pst:python-refactor"
  "pst:quality-gates"
  "pst:qa"
  "pst:rebase"
  "pst:resolve-threads"
  "pst:react-refactor"
  "pst:ready"
  "pst:sweep"
  "pst:slop"
  "spec-gen"
  "validate-quality-gates"
)

# Old names that may exist as orphaned symlinks
OLD_SKILLS=(
  "pst-code-review"
  "pst-qa"
)

usage() {
  cat <<'EOF'
Usage: ./install.sh [--claude] [--codex] [--pi] [--uninstall] [-h|--help]

Defaults to installing or uninstalling Claude, Codex, and Pi.

Options:
  --claude     Operate on Claude only
  --codex      Operate on Codex only
  --pi         Operate on Pi Coding Agent only
  --uninstall  Remove installed symlinks/wrappers instead of creating them
  -h, --help   Show this message
EOF
}

for arg in "$@"; do
  case "$arg" in
    --claude)
      WANTS_CLAUDE=true
      ;;
    --codex)
      WANTS_CODEX=true
      ;;
    --pi)
      WANTS_PI=true
      ;;
    --uninstall)
      UNINSTALL=true
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

INSTALL_CLAUDE=false
INSTALL_CODEX=false
INSTALL_PI=false
if [[ "$WANTS_CLAUDE" == true || "$WANTS_CODEX" == true || "$WANTS_PI" == true ]]; then
  INSTALL_CLAUDE="$WANTS_CLAUDE"
  INSTALL_CODEX="$WANTS_CODEX"
  INSTALL_PI="$WANTS_PI"
else
  INSTALL_CLAUDE=true
  INSTALL_CODEX=true
  INSTALL_PI=true
fi

portable_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/-+/-/g; s/^-//; s/-$//'
}

write_pi_wrapper() {
  local skill="$1"
  local safe
  safe="$(portable_name "$skill")"
  local src_dir="$REPO_DIR/skills/$skill"
  local src_file="$src_dir/SKILL.md"
  local dst_dir="$PI_SKILLS_DIR/$safe"
  mkdir -p "$dst_dir"
  {
    echo "---"
    echo "name: $safe"
    python3 - "$src_file" <<'PY'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text()
desc = "Personal workflow skill mirrored for Pi Coding Agent."
if text.startswith("---\n"):
    end = text.find("\n---", 4)
    if end != -1:
        m = re.search(r"^description:\s*(.+)$", text[4:end], re.M)
        if m:
            desc = m.group(1).strip().strip('"').strip("'")
print('description: "' + desc.replace('\\', '\\\\').replace('"', '\\"') + '"')
PY
    echo "compatibility: \"Portable Pi wrapper for original skill $skill.\""
    echo "metadata:"
    echo "  original_name: \"$skill\""
    echo "  original_path: \"$src_dir\""
    echo "---"
    echo ""
    echo "# Pi wrapper for \`$skill\`"
    echo ""
    echo "Original skill directory: \`$src_dir\`"
    echo ""
    echo "Cross-harness instructions: resolve relative files, scripts, references, and assets against the original skill directory above, not this wrapper directory."
    echo ""
    echo "---"
    echo ""
    python3 - "$src_file" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
if text.startswith("---\n"):
    end = text.find("\n---", 4)
    if end != -1:
        text = text[end+4:].lstrip("\n")
print(text.rstrip())
PY
  } > "$dst_dir/SKILL.md"
}

# ── Uninstall ────────────────────────────────────────────────────────
if [[ "$UNINSTALL" == true ]]; then
  for skill in "${SKILLS[@]}" "${OLD_SKILLS[@]}"; do
    claude_dst="$CLAUDE_COMMANDS_DIR/$skill.md"
    if [[ "$INSTALL_CLAUDE" == true && -L "$claude_dst" ]]; then
      rm "$claude_dst"
      echo "Uninstalled /$skill from Claude Code (removed $claude_dst)"
    fi

    codex_dst="$CODEX_SKILLS_DIR/$skill"
    if [[ "$INSTALL_CODEX" == true && -L "$codex_dst" ]]; then
      rm "$codex_dst"
      echo "Uninstalled /$skill from Codex (removed $codex_dst)"
    fi

    pi_dst="$PI_SKILLS_DIR/$(portable_name "$skill")"
    if [[ "$INSTALL_PI" == true && -d "$pi_dst" ]]; then
      rm -rf "$pi_dst"
      echo "Uninstalled /$(portable_name "$skill") from Pi (removed $pi_dst)"
    fi
  done
  exit 0
fi

# ── Detect available CLIs ────────────────────────────────────────────
if [[ "$INSTALL_CLAUDE" == true ]]; then
  mkdir -p "$CLAUDE_COMMANDS_DIR"
fi

CODEX_AVAILABLE=false
if [[ "$INSTALL_CODEX" == true && ("$CODEX_HOME_SET" == true || -d "$CODEX_HOME" || -x "$(command -v codex 2>/dev/null)" || "$WANTS_CODEX" == true) ]]; then
  mkdir -p "$CODEX_HOME"
  mkdir -p "$CODEX_SKILLS_DIR"
  CODEX_AVAILABLE=true
fi

PI_AVAILABLE=false
if [[ "$INSTALL_PI" == true && ("$PI_HOME_SET" == true || -d "$PI_HOME" || -x "$(command -v pi 2>/dev/null)" || "$WANTS_PI" == true) ]]; then
  mkdir -p "$PI_HOME"
  mkdir -p "$PI_SKILLS_DIR"
  PI_AVAILABLE=true
fi

# ── Clean up orphaned symlinks ───────────────────────────────────────
for old in "${OLD_SKILLS[@]}"; do
  claude_dst="$CLAUDE_COMMANDS_DIR/$old.md"
  if [[ "$INSTALL_CLAUDE" == true && -L "$claude_dst" ]]; then
    rm "$claude_dst"
    echo "Removed orphaned /$old -> $claude_dst"
  fi

  if [[ "$INSTALL_CODEX" == true && "$CODEX_AVAILABLE" == true ]]; then
    codex_dst="$CODEX_SKILLS_DIR/$old"
    if [[ -L "$codex_dst" ]]; then
      rm "$codex_dst"
      echo "Removed orphaned /$old -> $codex_dst (Codex)"
    fi
  fi

  if [[ "$INSTALL_PI" == true && "$PI_AVAILABLE" == true ]]; then
    pi_dst="$PI_SKILLS_DIR/$(portable_name "$old")"
    if [[ -d "$pi_dst" ]]; then
      rm -rf "$pi_dst"
      echo "Removed orphaned /$(portable_name "$old") -> $pi_dst (Pi)"
    fi
  fi
done

# ── Install skills ───────────────────────────────────────────────────
for skill in "${SKILLS[@]}"; do
  # Claude Code: file symlink to SKILL.md
  claude_src="$REPO_DIR/skills/$skill/SKILL.md"
  claude_dst="$CLAUDE_COMMANDS_DIR/$skill.md"
  if [[ "$INSTALL_CLAUDE" == true ]]; then
    ln -sfn "$claude_src" "$claude_dst"
    echo "Installed /$skill -> $claude_src"
  fi

  # Codex: directory symlink to skill folder (includes scripts/ etc.)
  if [[ "$INSTALL_CODEX" == true && "$CODEX_AVAILABLE" == true ]]; then
    codex_src="$REPO_DIR/skills/$skill"
    codex_dst="$CODEX_SKILLS_DIR/$skill"
    ln -sfn "$codex_src" "$codex_dst"
    echo "Installed /$skill -> $codex_src (Codex)"
  fi

  # Pi: portable wrapper directory with Agent Skills-safe name.
  if [[ "$INSTALL_PI" == true && "$PI_AVAILABLE" == true ]]; then
    write_pi_wrapper "$skill"
    echo "Installed /skill:$(portable_name "$skill") -> $REPO_DIR/skills/$skill (Pi wrapper)"
  fi
done

# ── External skill dependencies ──────────────────────────────────────
# pst:react-refactor layers on Vercel's react-best-practices.
# pst:figma layers on Figma's implement-design.
# Install globally so every project gets the latest industry rules.
# NOTE: These are Claude Code-specific via `npx skills add -g`.

EXTERNAL_SKILLS=(
  "vercel-labs/agent-skills"
  "https://github.com/figma/mcp-server-guide"
)

if [[ "$INSTALL_CLAUDE" == true ]] && command -v npx &>/dev/null; then
  for ext in "${EXTERNAL_SKILLS[@]}"; do
    echo ""
    echo "Installing external dependency: $ext"
    # shellcheck disable=SC2086
    npx -y skills@latest add $ext -g -y 2>&1 | sed 's/^/  /' || echo "  WARNING: Failed to install $ext (non-fatal)"
  done
elif [[ "$INSTALL_CLAUDE" == true ]]; then
  echo ""
  echo "WARNING: npx not found - skipping external skill dependencies."
  echo "         Install Node.js and run ./install.sh again to get external skills."
fi

# ── Summary ──────────────────────────────────────────────────────────
echo ""
if [[ "$INSTALL_CLAUDE" == true && "$INSTALL_CODEX" == true && "$INSTALL_PI" == true ]]; then
  echo "Skills installed for Claude Code, OpenAI Codex, and Pi (${#SKILLS[@]} skills)"
elif [[ "$INSTALL_CLAUDE" == true && "$INSTALL_CODEX" == true ]]; then
  echo "Skills installed for Claude Code and OpenAI Codex (${#SKILLS[@]} skills)"
elif [[ "$INSTALL_CLAUDE" == true && "$INSTALL_PI" == true ]]; then
  echo "Skills installed for Claude Code and Pi (${#SKILLS[@]} skills)"
elif [[ "$INSTALL_CODEX" == true && "$INSTALL_PI" == true ]]; then
  echo "Skills installed for OpenAI Codex and Pi (${#SKILLS[@]} skills)"
elif [[ "$INSTALL_CLAUDE" == true ]]; then
  echo "Skills installed for Claude Code only (${#SKILLS[@]} skills -> ~/.claude/commands/)"
fi
if [[ "$INSTALL_CODEX" == true && "$CODEX_AVAILABLE" == true ]]; then
  echo "Skills installed for OpenAI Codex  (${#SKILLS[@]} skills -> $CODEX_SKILLS_DIR/)"
  echo "Restart Codex to pick up new skills."
elif [[ "$INSTALL_CODEX" == true ]]; then
  echo "Codex CLI not detected and CODEX_HOME not set -- skipping Codex install."
  echo "Re-run ./install.sh after installing Codex or set CODEX_HOME to enable."
fi
if [[ "$INSTALL_PI" == true && "$PI_AVAILABLE" == true ]]; then
  echo "Pi skills installed (${#SKILLS[@]} wrappers -> $PI_SKILLS_DIR/)"
  echo "Restart Pi to pick up new skills. Colon names use portable aliases like pst-push."
elif [[ "$INSTALL_PI" == true ]]; then
  echo "Pi CLI not detected and PI_HOME not set -- skipping Pi install."
  echo "Re-run ./install.sh after installing Pi or set PI_HOME to enable."
fi
echo ""
if [[ "$INSTALL_CLAUDE" == true ]]; then
  echo "Claude commands: /decide-for-me, /pst:auto, /pst:claude-md, /pst:code-review, /pst:demo, /pst:figma, /pst:ingest-pdf, /pst:markdown, /pst:next, /pst:patch, /pst:push, /pst:python-refactor, /pst:qa, /pst:quality-gates, /pst:react-refactor, /pst:ready, /pst:rebase, /pst:resolve-threads, /pst:slop, /pst:sweep, /spec-gen, /validate-quality-gates"
fi
if [[ "$INSTALL_CODEX" == true && "$CODEX_AVAILABLE" == true ]]; then
  echo "Codex skills: mention the skill name in your prompt, for example: 'Use pst:push to push this branch and validate the PR.'"
fi
if [[ "$INSTALL_PI" == true && "$PI_AVAILABLE" == true ]]; then
  echo "Pi skills: use /skill:pst-push (or mention pst:push by name)."
fi
