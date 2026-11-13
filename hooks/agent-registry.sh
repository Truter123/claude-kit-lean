#!/usr/bin/env bash
# SubagentStart / SubagentStop / SessionEnd handler: keeps the agent registry the guard reads
# (ADR 0010, amends ADR 0003).
#   SubagentStart  binds agent_id -> model. The model comes from the pending spawn record that
#                  agent-guard.sh wrote for this agent_type, else from the agent file's frontmatter,
#                  else "opus" (the old assumption). Also records the start time and agent_type
#                  for the run log.
#   SubagentStop   appends one TAB-separated line to runs.log, then deletes the agent_id binding:
#                    utc_time  session_id  agent_id  agent_type  model  duration_s  tool_calls  top_tools  effort
#                  tool_calls/top_tools come from the agent's transcript (agent_transcript_path)
#                  when readable and <=20MB (counted with jq); above that cap tool_calls falls back
#                  to a grep count and top_tools is "n/a". effort is the input's effort.level: the
#                  level the subagent actually ran at (ADR 0024), empty on a model without effort.
#                  Type and model fall back, in order: the binding, the .done record of an
#                  earlier stop, then the input's agent_type and that agent file's model pin.
#                  A resumed agent (second stop, no new start) logs a line with only its new
#                  calls, top_tools "resumed" and no duration. A stop with no type, no start
#                  and no calls is not logged (17k such lines Sept-Oct 2026, audit 2026-11-10).
#                  Logging never blocks the hook: failures are swallowed.
#   SessionEnd     deletes the session's registry directory.
# Never blocks: always exits 0.
set -u
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
INPUT=$(cat) || exit 0
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null) || exit 0
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // "default"' 2>/dev/null) || exit 0
REG="${TMPDIR:-/tmp}/claude-agent-guard-$(id -u)/$SESSION"

case "$EVENT" in
  SubagentStart)
    AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null)
    AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // "general-purpose"' 2>/dev/null)
    [ -z "$AGENT_ID" ] && exit 0
    mkdir -p "$REG/agents" "$REG/pending"
    MODEL=""
    [ -f "$REG/pending/$AGENT_TYPE" ] && MODEL=$(cat "$REG/pending/$AGENT_TYPE")
    AGENT_FILE="$CFG/agents/${AGENT_TYPE##*:}.md"
    [ -z "$MODEL" ] && [ -f "$AGENT_FILE" ] && MODEL=$(sed -n 's/^model:[[:space:]]*//p' "$AGENT_FILE" | head -1)
    [ -z "$MODEL" ] && MODEL=opus
    printf '%s\n' "$MODEL" > "$REG/agents/$AGENT_ID"
    date +%s > "$REG/agents/$AGENT_ID.start"
    printf '%s\n' "$AGENT_TYPE" > "$REG/agents/$AGENT_ID.type"
    ;;
  SubagentStop)
    AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // ""' 2>/dev/null)
    if [ -n "$AGENT_ID" ]; then
      {
        # A second stop of the same agent_id (resumed after its first stop, no new
        # SubagentStart) finds the binding gone: the .done record carries type, model and the
        # calls already logged.
        DONE="$REG/agents/$AGENT_ID.done"
        RESUMED=0; PREV_TYPE=""; PREV_MODEL=""; PREV_CALLS=""
        if [ -f "$DONE" ]; then
          RESUMED=1
          { read -r PREV_TYPE; read -r PREV_MODEL; read -r PREV_CALLS; } < "$DONE"
        fi
        case "$PREV_CALLS" in ''|*[!0-9]*) PREV_CALLS=0 ;; esac
        RUN_TYPE=""
        [ -f "$REG/agents/$AGENT_ID.type" ] && RUN_TYPE=$(cat "$REG/agents/$AGENT_ID.type")
        [ -z "$RUN_TYPE" ] && RUN_TYPE=$PREV_TYPE
        [ -z "$RUN_TYPE" ] && RUN_TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // ""' 2>/dev/null)
        RUN_MODEL=""
        [ -f "$REG/agents/$AGENT_ID" ] && RUN_MODEL=$(cat "$REG/agents/$AGENT_ID")
        [ -z "$RUN_MODEL" ] && RUN_MODEL=$PREV_MODEL
        if [ -z "$RUN_MODEL" ] && [ -n "$RUN_TYPE" ]; then
          PIN_FILE="$CFG/agents/${RUN_TYPE##*:}.md"
          [ -f "$PIN_FILE" ] && RUN_MODEL=$(sed -n 's/^model:[[:space:]]*//p' "$PIN_FILE" | head -1)
        fi
        case "$RUN_MODEL" in ''|inherit) RUN_MODEL=unknown ;; esac
        DURATION=""
        if [ -f "$REG/agents/$AGENT_ID.start" ]; then
          START=$(cat "$REG/agents/$AGENT_ID.start")
          NOW=$(date +%s)
          DURATION=$((NOW - START))
        fi
        TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.agent_transcript_path // ""' 2>/dev/null)
        TRANSCRIPT="${TRANSCRIPT/#\~/$HOME}"
        TOOL_CALLS=""
        TOP_TOOLS=""
        if [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ]; then
          SIZE=$(stat -c%s "$TRANSCRIPT" 2>/dev/null || echo 0)
          if [ "$SIZE" -le 20971520 ]; then
            COUNTS=$(jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | .name' "$TRANSCRIPT" 2>/dev/null | sort | uniq -c | sort -rn)
            TOOL_CALLS=$(printf '%s\n' "$COUNTS" | awk '{s+=$1} END{print s+0}')
            TOP_TOOLS=$(printf '%s\n' "$COUNTS" | head -3 | awk '{printf "%s%s:%s", (NR>1?",":""), $2, $1}')
          else
            TOOL_CALLS=$(grep -c '"type":"tool_use"' "$TRANSCRIPT" 2>/dev/null)
            TOP_TOOLS="n/a"
          fi
        fi
        EFFORT=$(printf '%s' "$INPUT" | jq -r '.effort.level // ""' 2>/dev/null)
        # TOTAL = every call in the transcript so far; a resumed leg logs only its new calls, so
        # the sum of field 7 stays the real number of calls.
        TOTAL=$TOOL_CALLS
        case "$TOTAL" in ''|*[!0-9]*) TOTAL=$PREV_CALLS ;; esac
        if [ "$RESUMED" -eq 1 ]; then
          TOOL_CALLS=$((TOTAL - PREV_CALLS))
          [ "$TOOL_CALLS" -lt 0 ] && TOOL_CALLS=0
          TOP_TOOLS=resumed
        fi
        # A stop with no type, no start time and no calls says nothing: not logged.
        if [ -n "$RUN_TYPE" ] || [ -n "$DURATION" ] || [ "$TOTAL" -gt 0 ]; then
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(date -u +%FT%TZ)" "$SESSION" "$AGENT_ID" "$RUN_TYPE" "$RUN_MODEL" "$DURATION" "$TOOL_CALLS" "$TOP_TOOLS" "$EFFORT" \
            >> "$CFG/runs.log"
          mkdir -p "$REG/agents" && printf '%s\n%s\n%s\n' "$RUN_TYPE" "$RUN_MODEL" "$TOTAL" > "$DONE"
        fi
      } 2>/dev/null || true
      rm -f "$REG/agents/$AGENT_ID" "$REG/agents/$AGENT_ID.start" "$REG/agents/$AGENT_ID.type" "$REG/agents/$AGENT_ID.calls"
    fi
    ;;
  SessionEnd)
    rm -rf "$REG"
    ;;
esac
exit 0
