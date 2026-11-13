#!/usr/bin/env bash
# Maintainer script: refresh hooks/ with plain copies of the home hooks.
# Run on the home machine. The home directory stays the source of truth.
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks"
DEST="$KIT/hooks"
HOOKS=(agent-guard.sh agent-registry.sh budget-guard.sh cg-sync.sh)

for h in "${HOOKS[@]}"; do
  if [ ! -f "$SRC/$h" ]; then
    echo "sync-from-home: missing source $SRC/$h" >&2
    exit 1
  fi
done

mkdir -p "$DEST"
for h in "${HOOKS[@]}"; do
  rm -f "$DEST/$h"
  cp "$SRC/$h" "$DEST/$h"
  chmod +x "$DEST/$h"
done

bad=0
for h in "${HOOKS[@]}"; do
  if grep -nE '/home/[A-Za-z0-9_.-]+' "$DEST/$h" >&2; then
    echo "sync-from-home: $h holds a machine-specific home path; fix it in the home hooks" >&2
    bad=1
  fi
done
[ "$bad" -eq 0 ] || exit 1

for h in "${HOOKS[@]}"; do
  echo "$DEST/$h"
done
