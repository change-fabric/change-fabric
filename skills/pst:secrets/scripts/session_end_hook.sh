#!/usr/bin/env bash
# Claude Code SessionEnd hook for pst:secrets.
#
# Shreds any live session cache when a Claude Code session ends, so materialized
# plaintext secrets never outlive the session that asked for them. Registered by
# `/pst:secrets session install-hook`. Reads (and ignores) the hook JSON on
# stdin; never blocks session exit.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd)"
python3 "$SELF_DIR/session_cache.py" end --quiet --reason session-end-hook \
  >/dev/null 2>&1 || true
