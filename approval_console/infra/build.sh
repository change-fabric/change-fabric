#!/usr/bin/env bash
# Stages the Lambda package into build/package (what main.tf zips). Re-runnable:
# it rebuilds the directory from scratch every time. Needs no AWS access.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/build/package"

rm -rf "$out"
mkdir -p "$out"
cp "$here"/lambda/*.rb "$out/"
echo "staged $(find "$out" -type f | wc -l | tr -d ' ') files in $out"
