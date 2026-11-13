#!/usr/bin/env bash
# Guard probes for the kit hooks: a pure stdin -> exit-code check, free and instant.
# Tests <kit>/hooks/*.sh against the kit agents in a temporary CLAUDE_CONFIG_DIR.
#
# Usage: bash tests/guard.sh
# Exit 0 = all probes passed. Writes nothing under the real ~/.claude.

set -u
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT"

PASS=0
FAIL=0
PROBE_SESSION="kitprobe-$$"
PROBE_AGENT=E1

CFG_TMP=$(mktemp -d)
mkdir -p "$CFG_TMP/agents"
for a in scout worker engineer; do
  ln -s "$KIT/agents/$a.md" "$CFG_TMP/agents/$a.md"
done
printf '{"model":"opus"}\n' > "$CFG_TMP/settings.json"
export CLAUDE_CONFIG_DIR="$CFG_TMP"
RUNS_LOG="$CFG_TMP/runs.log"

ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# expect <wanted exit> <label> <json>
expect() {
  local want=$1 label=$2 json=$3 got
  printf '%s' "$json" | bash hooks/agent-guard.sh >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then ok "$label (exit $got)"; else bad "$label: expected exit $want, got $got"; fi
}

registry() { printf '%s' "$1" | bash hooks/agent-registry.sh >/dev/null 2>&1; }

cleanup() {
  registry "{\"session_id\":\"$PROBE_SESSION\",\"hook_event_name\":\"SessionEnd\"}"
  rm -rf "$CFG_TMP"
}
trap cleanup EXIT

echo "syntax"
for f in hooks/*.sh tests/*.sh sync-from-home.sh; do
  if bash -n "$f" 2>/dev/null; then ok "$f parses"; else bad "$f does not parse"; fi
done

echo "guard: from the main loop"
expect 2 "a bare Agent call is denied" \
  '{"tool_name":"Agent","tool_input":{"prompt":"x"}}'
for a in scout worker engineer; do
  expect 0 "$a is allowed (model read from agents/$a.md)" \
    "{\"tool_name\":\"Agent\",\"tool_input\":{\"prompt\":\"x\",\"subagent_type\":\"$a\"}}"
done
expect 2 "built-in Explore is denied, even with a model" \
  '{"tool_name":"Agent","tool_input":{"prompt":"x","subagent_type":"Explore","model":"sonnet"}}'
expect 2 "effort: max is denied" \
  '{"tool_name":"Agent","tool_input":{"prompt":"x","subagent_type":"engineer","effort":"max"}}'
expect 0 "a general call on sonnet is allowed" \
  '{"tool_name":"Agent","tool_input":{"prompt":"x","model":"sonnet"}}'
expect 2 "a general call on opus is denied (work goes down only)" \
  '{"tool_name":"Agent","tool_input":{"prompt":"x","model":"opus"}}'

echo "guard: from inside a subagent"
registry "{\"session_id\":\"$PROBE_SESSION\",\"hook_event_name\":\"SubagentStart\",\"agent_id\":\"$PROBE_AGENT\",\"agent_type\":\"engineer\"}"
expect 0 "engineer may spawn worker" \
  "{\"tool_name\":\"Agent\",\"session_id\":\"$PROBE_SESSION\",\"agent_id\":\"$PROBE_AGENT\",\"tool_input\":{\"prompt\":\"x\",\"subagent_type\":\"worker\"}}"
expect 2 "engineer may not spawn scout (sonnet peer)" \
  "{\"tool_name\":\"Agent\",\"session_id\":\"$PROBE_SESSION\",\"agent_id\":\"$PROBE_AGENT\",\"tool_input\":{\"prompt\":\"x\",\"subagent_type\":\"scout\"}}"

echo "budget: hard cap on tool calls (scout 30)"
i=1
while [ "$i" -le 31 ]; do
  printf '%s' "{\"tool_name\":\"Read\",\"session_id\":\"$PROBE_SESSION\",\"agent_id\":\"S1\",\"agent_type\":\"scout\"}" | bash hooks/budget-guard.sh >/dev/null 2>&1
  got=$?
  if [ "$i" -le 30 ]; then want=0; else want=2; fi
  if [ "$got" -ne "$want" ]; then bad "scout call $i: expected exit $want, got $got"; break; fi
  i=$((i + 1))
done
if [ "$i" -gt 31 ]; then ok "scout calls 1-30 allowed, call 31 denied (exit 2)"; fi

echo "run log"
registry "{\"session_id\":\"$PROBE_SESSION\",\"hook_event_name\":\"SubagentStop\",\"agent_id\":\"$PROBE_AGENT\"}"
COUNT=$(grep -c "$PROBE_AGENT" "$RUNS_LOG" 2>/dev/null || true)
if [ "${COUNT:-0}" -eq 1 ]; then ok "runs.log has exactly one line for $PROBE_AGENT"; else bad "runs.log has ${COUNT:-0} lines for $PROBE_AGENT, expected 1"; fi
LINE=$(grep "$PROBE_AGENT" "$RUNS_LOG" 2>/dev/null | tail -1)
if printf '%s' "$LINE" | awk -F'\t' '$3=="'"$PROBE_AGENT"'" || $2=="'"$PROBE_AGENT"'" {f=1} f && $4=="engineer" && $5=="sonnet"{exit 0} {exit 1}'; then
  ok "type=engineer model=sonnet"
else
  bad "type/model wrong in: $LINE"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
