#!/usr/bin/env bash
# PreToolUse guard on every tool: a hard cap on tool calls per subagent run (ADR 0022).
# maxTurns counts turns, and one turn can carry several tool calls, so it never capped them (109
# calls seen under maxTurns: 50). The budget written in agents/*.md stays the target; this is the
# stop at 2x budget: engineer 50, validator 50, auditor 40, scout 30, explorer 20. Runs of 159 calls
# were logged with no cap at all (audit 2026-11-10); the 2026-11-12 measurement (237 runs, 94% of
# code questions end within 30 calls) set the scout number.
# Counter: <registry>/agents/<agent_id>.calls, removed by agent-registry.sh on SubagentStop.
# Exit 2 + stderr denies the call and tells the agent to report. Any failure here lets the call
# through: a budget is not a security boundary.
set -u
INPUT=$(cat) || exit 0
# Fast path: the main loop has no agent_id, so it never pays for jq.
case "$INPUT" in *'"agent_id"'*) ;; *) exit 0 ;; esac

# Windows (Git Bash): jq.exe writes CRLF unless -b; a trailing \r breaks every comparison.
case "${KIT_OS:-${OSTYPE:-}}" in msys*|cygwin*|windows) jq() { command jq -b "$@"; } ;; esac
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null) || exit 0
[ -n "$AGENT_ID" ] || exit 0
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null) || exit 0
TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // ""' 2>/dev/null) || exit 0
AGENTS="${TMPDIR:-/tmp}/claude-agent-guard-$(id -u)/$SESSION/agents"
if [ -z "$TYPE" ] && [ -f "$AGENTS/$AGENT_ID.type" ]; then
  TYPE=$(cat "$AGENTS/$AGENT_ID.type")
fi

# A plugin agent arrives namespaced (plugin:engineer).
TYPE=${TYPE##*:}
case "$TYPE" in
  engineer|validator) CAP=50 ;;
  scout) CAP=30 ;;
  explorer) CAP=20 ;;
  auditor) CAP=40 ;;
  *) exit 0 ;;
esac

mkdir -p "$AGENTS" 2>/dev/null || exit 0
FILE="$AGENTS/$AGENT_ID.calls"
N=0
[ -f "$FILE" ] && N=$(cat "$FILE" 2>/dev/null)
case "$N" in ''|*[!0-9]*) N=0 ;; esac
N=$((N + 1))
printf '%s\n' "$N" > "$FILE" 2>/dev/null || exit 0
if [ "$N" -gt "$CAP" ]; then
  echo "budget: $TYPE used its hard cap of $CAP tool calls. Stop now and write your report: what is done and what is missing." >&2
  exit 2
fi
exit 0
