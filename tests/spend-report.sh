#!/usr/bin/env bash
# Probes for bin/spend-report.sh: tiny transcript fixtures -> the report, under a throwaway config dir.
# Usage: bash tests/spend-report.sh   (exit 0 = all probes passed; touches nothing real)

set -u
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$KIT/bin/spend-report.sh"
REAL_JQ=$(command -v jq)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

N=0
newcfg() { N=$((N + 1)); CFG="$TMP/cfg$N"; mkdir -p "$CFG/projects/p1"; }

# a <ts> <msg id> <model> <input> <cache_creation> <cache_read> <output> [1h write tokens]
# (with the 1h argument the usage carries a cache_creation object; without it only the total)
a() {
  local extra=
  [ -n "${8:-}" ] && extra=",\"cache_creation\":{\"ephemeral_1h_input_tokens\":$8,\"ephemeral_5m_input_tokens\":0}"
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"%s","model":"%s","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s%s}}}\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$extra"
}
# u <ts>  (a human message)
u() { printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"hello"}}\n' "$1"; }

run() { CLAUDE_CONFIG_DIR="$CFG" bash "$SCRIPT" "$@"; }

eq() { # eq <label> <want> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: wanted [$2] got [$3]"; fi
}
norm() { tr -s ' '; }
has() { # has <label> <exact normalised line> <report>
  if printf '%s\n' "$3" | norm | grep -Fxq -- "$2"; then ok "$1"; else bad "$1: no line [$2] in:"$'\n'"$3"; fi
}

S=claude-sonnet-5-5
T0=2026-11-16T10:00:00Z

# 1. duplicate message id: the last line wins. Output 500000 tokens: 2e-6 * 5 * 500000 = 5.00
newcfg
{
  a "$T0" m1 $S 0 0 0 100
  a 2026-11-16T10:00:01Z m1 $S 0 0 0 500000
} >"$CFG/projects/p1/s1.jsonl"
out=$(run)
has "duplicate id: one request, last output counted" 'main sonnet 1 5.00 0.00 0.00 5.00' "$out"
has "duplicate id: total" 'total $5.00' "$out"
has "header" 'spend report: last 7 days, list price, this machine' "$out"

# 2. 10-minute gap after a human message.
#    A1: 1h write 1,000,000 -> write 2e-6*2*1e6 = 4.00.  A2: cache read 1,000,000 -> read 2e-6*0.05*1e6 = 0.10,
#    output 100,000 -> 2e-6*5*1e5 = 1.00.  Total 5.10.
#    X = 2e-6*0.75*1e6 = 1.50.  Y = 2e-6*(1.25-0.05)*1e6 = 2.40 -> pays; the 5-60 min prompt is all cache: 100%.
newcfg
{
  a "$T0" m1 $S 0 1000000 0 0 1000000
  u 2026-11-16T10:09:59Z
  a 2026-11-16T10:10:00Z m2 $S 0 0 1000000 100000
} >"$CFG/projects/p1/s2.jsonl"
out2=$(run)
has "10 min gap: main row" 'main sonnet 2 5.10 4.00 0.10 1.00' "$out2"
has "10 min gap: 5-60 min after a message" '5-60 min 1 1' "$out2"
has "10 min gap: other classes empty" 'over 60 min 0 0' "$out2"
has "10 min gap: prompt size" 'over 200k 2 5.10 100%' "$out2"
has "10 min gap: 1-hour cache pays" '1-hour cache: extra write cost $1.50, re-sends avoided $2.40: pays. After a 5-60 min gap 100% of the prompt came from the cache.' "$out2"
has "10 min gap: session bucket" 'sessions by cost: under $1: 0 ($0.00) | $1-5: 0 ($0.00) | $5-20: 1 ($5.10) | over $20: 0 ($0.00)' "$out2"

# 3. 2-hour gap, no 1h writes. A2: 5m write via the total only: 2e-6*1.25*500000 = 1.25
newcfg
{
  a "$T0" m1 $S 10 0 0 0
  a 2026-11-16T12:00:00Z m2 $S 0 500000 0 0
} >"$CFG/projects/p1/s3.jsonl"
out=$(run)
has "2 h gap: over 60 min" 'over 60 min 1 0' "$out"
has "2 h gap: rewrite cost" 'back after more than 60 min: 1 times, $1.25 in total, $1.25 each' "$out"
has "no 1h writes line" '1-hour cache: no 1-hour writes reported. After a 5-60 min gap 0% of the prompt came from the cache.' "$out"

# 4. subagent file, haiku 5.5 (0.1 per million): 5m write 2e6 -> 0.1e-6*1.25*2e6 = 0.25, output 1e6 -> 0.50, total 0.75
newcfg
mkdir -p "$CFG/projects/p1/sess1/subagents"
a "$T0" m1 claude-haiku-5-5 0 2000000 0 1000000 >"$CFG/projects/p1/sess1/subagents/agent-x.jsonl"
out=$(run)
has "subagent: sub haiku row" 'sub haiku 1 0.75 0.25 0.00 0.50' "$out"
has "subagent: total" 'total $0.75' "$out"
has "subagent: not in prompt size" 'over 200k 0 0.00 0%' "$out"
has "subagent: not in gaps" 'under 5 min 0 0' "$out"
eq "subagent: no main row" 0 "$(printf '%s\n' "$out" | grep -c '^main')"

# 5. unknown model id (ARN without a model name): priced as Sonnet 5.5, output 1e6 -> 2e-6*5*1e6 = 10.00
newcfg
a "$T0" m1 'arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/abc123' 0 0 0 1000000 >"$CFG/projects/p1/s5.jsonl"
out=$(run)
has "unknown model: row" 'main unknown 1 10.00 0.00 0.00 10.00' "$out"
has "unknown model: last line" 'unknown model id (priced as Sonnet): 1 requests' "$out"
newcfg
a "$T0" m1 $S 0 0 0 1000000 >"$CFG/projects/p1/s5b.jsonl"
case "$(run)" in *'unknown model id'*) bad "unknown line printed for a known model";; *) ok "no unknown line for a known model";; esac

# 6. Windows mode: fake jq writes CRLF; the script must call it with -b and strip CR itself
mkdir -p "$TMP/fakebin"
cat >"$TMP/fakebin/jq" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >>"$TMP/jq-args"
"$REAL_JQ" "\$@" | while IFS= read -r l; do printf '%s\r\n' "\$l"; done
EOF
chmod +x "$TMP/fakebin/jq"
newcfg
{
  a "$T0" m1 $S 0 1000000 0 0 1000000
  u 2026-11-16T10:09:59Z
  a 2026-11-16T10:10:00Z m2 $S 0 0 1000000 100000
} >"$CFG/projects/p1/s2.jsonl"
outw=$(env PATH="$TMP/fakebin:$PATH" KIT_OS=windows CLAUDE_CONFIG_DIR="$CFG" bash "$SCRIPT")
eq "windows mode: same output as case 2" "$out2" "$outw"
case "$outw" in *$'\r'*) bad "CR in output";; *) ok "no CR in output";; esac
eq "windows mode: jq called with -b" "-b" "$(head -n1 "$TMP/jq-args")"

# 7. privacy: message text never reaches the report
newcfg
{
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"SECRETTEXT question"}}\n' "$T0"
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":[{"type":"tool_result","content":"SECRETTEXT"}]}}\n' "$T0"
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"m1","model":"%s","content":[{"type":"text","text":"SECRETTEXT reply"}],"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1000000}}}\n' "$T0" "$S"
} >"$CFG/projects/p1/s7.jsonl"
out=$(run)
has "privacy: request still counted" 'main sonnet 1 10.00 0.00 0.00 10.00' "$out"
case "$out" in *SECRETTEXT*) bad "message text leaked into the report";; *) ok "message text does not appear in the report";; esac

# 8. no projects dir, and the days argument
newcfg
rmdir "$CFG/projects/p1" "$CFG/projects"
out=$(run); rc=$?
eq "no projects dir: line" 'spend report: no session files in the last 7 days' "$out"
eq "no projects dir: exit 0" 0 "$rc"
out=$(run abc)
eq "non-number days means 7" 'spend report: no session files in the last 7 days' "$out"
out=$(run 30)
eq "days argument" 'spend report: no session files in the last 30 days' "$out"

# 9. malformed line does not break the report
newcfg
{
  a "$T0" m1 $S 0 0 0 500000
  printf 'not json {{\n'
  printf '{"type":"assistant","timestamp":\n'
} >"$CFG/projects/p1/s9.jsonl"
out=$(run); rc=$?
has "malformed line: report intact" 'main sonnet 1 5.00 0.00 0.00 5.00' "$out"
eq "malformed line: exit 0" 0 "$rc"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
