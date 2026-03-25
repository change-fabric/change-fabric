#!/usr/bin/env bash
# lint-no-emdash.sh - Fail if any tracked file contains an em dash (U+2014).
set -euo pipefail

hits=$(git grep -rn $'\xe2\x80\x94' -- '*.md' '*.sh' '*.js' '*.ts' '*.json' || true)

if [ -n "$hits" ]; then
  echo "ERROR: Em dashes found in the following locations:"
  echo "$hits"
  echo ""
  echo "Replace every em dash (-) with a regular hyphen-minus (-) or rephrase."
  exit 1
fi

echo "No em dashes found."
