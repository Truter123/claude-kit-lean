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
MODE=""
REAL_JQ=$(command -v jq)
ORIG_PATH=$PATH
# Fake jq for the "Windows" run: like jq.exe it ends every output line with \r unless -b is given.
FAKE_JQ_BIN="$CFG_TMP/fakejq"
mkdir -p "$FAKE_JQ_BIN"
cat > "$FAKE_JQ_BIN/jq" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "-b" ] && exec "$REAL_JQ" "\$@"; done
"$REAL_JQ" "\$@" | sed 's/\$/\r/'
exit \${PIPESTATUS[0]}
EOF
chmod +x "$FAKE_JQ_BIN/jq"

ok()   { PASS=$((PASS + 1)); printf '  ok    %s%s\n' "$MODE" "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s%s\n' "$MODE" "$1"; }

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

run_suite() {
PROBE_SESSION="kitprobe-$$-${MODE//[^a-z]/}"
rm -f "$RUNS_LOG"
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

echo "guard: transcript_path with backslashes (Windows path)"
for m in claude-opus-4-7 claude-sonnet-4-5; do
  TR="$CFG_TMP/transcript-$m.jsonl"
  printf '{"type":"assistant","message":{"model":"%s"}}\n' "$m" > "$TR"
  TRBS=${TR//\//\\}
  JSON=$("$REAL_JQ" -nc --arg p "$TRBS" '{tool_name:"Agent",transcript_path:$p,tool_input:{prompt:"x",subagent_type:"scout"}}')
  case "$m" in
    *opus*)   expect 0 "scout allowed when the backslash transcript says opus" "$JSON" ;;
    *sonnet*) expect 2 "scout denied when the backslash transcript says sonnet" "$JSON" ;;
  esac
done

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
registry "{\"session_id\":\"$PROBE_SESSION\",\"hook_event_name\":\"SessionEnd\"}"
}

MODE=""
run_suite

# Windows mode: Git Bash reports msys, and jq.exe writes CRLF unless -b.
echo "windows mode (KIT_OS=windows, jq without -b ends lines with CR)"
export KIT_OS=windows
PATH="$FAKE_JQ_BIN:$ORIG_PATH"
MODE="[windows] "
run_suite
PATH=$ORIG_PATH
unset KIT_OS
MODE=""

echo "cg-sync: .mcp.json paths, jq instead of python3, git state"
CG_TMP=$(mktemp -d)
mkdir -p "$CG_TMP/fake" "$CG_TMP/fakecyg" "$CG_TMP/home"
cat > "$CG_TMP/fake/java" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$CG_TMP/java.args"
EOF
cat > "$CG_TMP/fake/python3" <<EOF
#!/usr/bin/env bash
touch "$CG_TMP/python3.used"
exit 1
EOF
cat > "$CG_TMP/fakecyg/cygpath" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do last=$a; done
printf 'C:%s\n' "$last"
EOF
chmod +x "$CG_TMP"/fake/* "$CG_TMP"/fakecyg/*
: > "$CG_TMP/dummy.jar"

# cg_repo <name>: a fresh git repo holding one tracked .java file
cg_repo() {
  local r="$CG_TMP/$1"
  mkdir -p "$r"
  git -C "$r" init -q
  echo 'class Foo {}' > "$r/Foo.java"
  git -C "$r" add Foo.java
  echo "$r"
}
# cg_run <repo> <extra PATH prefix>
cg_run() {
  rm -f "$CG_TMP/java.args"
  HOME="$CG_TMP/home" CODE_NAVIGATOR_JAR="$CG_TMP/dummy.jar" PATH="$2$CG_TMP/fake:$ORIG_PATH" \
    bash hooks/cg-sync.sh "$1" >/dev/null 2>&1
}

R=$(cg_repo winpaths)
cg_run "$R" "$CG_TMP/fakecyg:"
JARARG=$("$REAL_JQ" -r '.mcpServers["code-navigator"].args[1]' "$R/.mcp.json" 2>/dev/null)
PROJ=$("$REAL_JQ" -r '.mcpServers["code-navigator"].env.CODE_NAVIGATOR_PROJECT' "$R/.mcp.json" 2>/dev/null)
case "$JARARG:$PROJ" in C:/*:C:/*) ok "cygpath present: .mcp.json jar and project start with C:/" ;; *) bad "cygpath present: jar='$JARARG' project='$PROJ'" ;; esac
if [ "$(grep -cE '^(-Dorg.sqlite.tmpdir=)?C:/' "$CG_TMP/java.args" 2>/dev/null)" -ge 3 ]; then ok "cygpath present: java arguments hold C:/ paths"; else bad "cygpath present: java args: $(tr '\n' ' ' < "$CG_TMP/java.args" 2>/dev/null)"; fi

R=$(cg_repo posix)
cg_run "$R" ""
JARARG=$("$REAL_JQ" -r '.mcpServers["code-navigator"].args[1]' "$R/.mcp.json" 2>/dev/null)
PROJ=$("$REAL_JQ" -r '.mcpServers["code-navigator"].env.CODE_NAVIGATOR_PROJECT' "$R/.mcp.json" 2>/dev/null)
if [ "$JARARG" = "$CG_TMP/dummy.jar" ] && [ "$PROJ" = "$R" ]; then ok "no cygpath: .mcp.json paths unchanged"; else bad "no cygpath: jar='$JARARG' project='$PROJ'"; fi
if grep -qxF "$R" "$CG_TMP/java.args" 2>/dev/null && grep -qxF "$CG_TMP/dummy.jar" "$CG_TMP/java.args"; then ok "no cygpath: java arguments unchanged"; else bad "no cygpath: java args: $(tr '\n' ' ' < "$CG_TMP/java.args" 2>/dev/null)"; fi
if ! grep -q $'\r' "$R/.mcp.json"; then ok ".mcp.json has LF endings"; else bad ".mcp.json holds CR"; fi

R=$(cg_repo nopython)
rm -f "$CG_TMP/python3.used"
cg_run "$R" ""
if [ -f "$R/.mcp.json" ] && [ ! -f "$CG_TMP/python3.used" ]; then ok "python3 unusable: .mcp.json still written, python3 never called"; else bad "python3 unusable: file=$([ -f "$R/.mcp.json" ] && echo yes || echo no) python3-called=$([ -f "$CG_TMP/python3.used" ] && echo yes || echo no)"; fi

ST=$(git -C "$R" status --short)
if printf '%s' "$ST" | grep -qE '\.mcp\.json|navigators'; then bad "git status shows generated files: $ST"; else ok "git status shows neither .mcp.json nor navigators/"; fi
rm -rf "$CG_TMP"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
