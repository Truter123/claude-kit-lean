#!/usr/bin/env bash
# Probes for bin/statusline.sh: stdin JSON -> one status line, ledger under a throwaway data dir.
# Usage: bash tests/statusline.sh   (exit 0 = all probes passed; touches nothing real)

set -u
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$KIT/bin/statusline.sh"
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
newdata() { N=$((N + 1)); DATA="$TMP/data$N"; mkdir -p "$DATA"; }

# j <model|-> <cost|-> <ctx|-> <sid> [tokens]   ("-" leaves the field out; tokens is raw JSON for
#   total_input_tokens, left out when absent)
j() {
  local parts=()
  [ "$1" != - ] && parts+=("\"model\":{\"display_name\":\"$1\"}")
  [ "$2" != - ] && parts+=("\"cost\":{\"total_cost_usd\":$2}")
  local cw=()
  [ "$3" != - ] && cw+=("\"used_percentage\":$3")
  [ -n "${5:-}" ] && cw+=("\"total_input_tokens\":$5")
  if [ "${#cw[@]}" -gt 0 ]; then local IFS=,; parts+=("\"context_window\":{${cw[*]}}"); fi
  parts+=("\"session_id\":\"$4\"")
  local IFS=,
  printf '{%s}' "${parts[*]}"
}

# run <json> [VAR=value ...]  (uses $DATA; defaults: NO_COLOR=1, KIT_TODAY=2026-11-16)
run() {
  local json=$1; shift
  printf '%s' "$json" | env XDG_DATA_HOME="$DATA" NO_COLOR=1 KIT_TODAY=2026-11-16 "$@" bash "$SCRIPT" 2>"$TMP/err"
}

eq() { # eq <label> <want> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: wanted [$2] got [$3]"; fi
}

SONNET=$(j "Sonnet 5.5" 1.42 38.4 s1)

# 1. exact line
newdata
eq "single session line" 'Sonnet 5.5 | session $1.42 | month $1 / $250 (pace $133) | ctx 38%' "$(run "$SONNET")"

# 2. two sessions; rounding is half up: 5.50 -> 6, 5.49 -> 5
newdata
run "$(j M 3.00 - a)" >/dev/null
out=$(run "$(j M 2.50 - b)")
case "$out" in *'month $6 /'*) ok "two sessions, 5.50 rounds up to 6";; *) bad "two sessions: $out";; esac
newdata
run "$(j M 3.00 - a)" >/dev/null
out=$(run "$(j M 2.49 - b)")
case "$out" in *'month $5 /'*) ok "two sessions, 5.49 rounds down to 5";; *) bad "5.49: $out";; esac

# 3. /clear: 30.00 then 4.00 -> month 34
newdata
run "$(j M 30.00 - a)" >/dev/null
out=$(run "$(j M 4.00 - a)")
case "$out" in *'session $4.00'*'month $34 /'*) ok "clear keeps the old cost (month 34)";; *) bad "clear: $out";; esac
eq "clear ledger content" "30.000000 4.000000" "$(IFS= read -r l <"$DATA/claude-kit/spend/2026-11/a"; printf '%s' "$l")"
newdata
run "$(j M 3.00 - a)" >/dev/null
out=$(run "$(j M 0.40 - a)")
case "$out" in *'session $0.40'*) ok "clear shows session 0.40";; *) bad "clear 0.40: $out";; esac
eq "clear ledger 3.00 -> 0.40" "3.000000 0.400000" "$(IFS= read -r l <"$DATA/claude-kit/spend/2026-11/a"; printf '%s' "$l")"

# 3b. an unchanged cost with many decimals is not a reset (the stored value is rounded; a refresh
#     with the same cost once counted the session again on every run)
newdata
for _ in 1 2 3 4; do run "$(j M 12.3456789 - a)" >/dev/null; done
out=$(run "$(j M 12.3456789 - a)")
case "$out" in *'month $12 /'*) ok "same cost five times stays month 12";; *) bad "repeat: $out";; esac
eq "repeat ledger base stays 0" "0.000000" "$(read -r b _ <"$DATA/claude-kit/spend/2026-11/a"; printf '%s' "$b")"

# 4. rising again after the reset: 30 -> 4 -> 9 gives 39, not 43
newdata
run "$(j M 30.00 - a)" >/dev/null
run "$(j M 4.00 - a)" >/dev/null
out=$(run "$(j M 9.00 - a)")
case "$out" in *'month $39 /'*) ok "cost rising after reset (month 39)";; *) bad "rise: $out";; esac

# 5. missing context_window / model
newdata
out=$(run "$(j M 1 - s)")
case "$out" in *ctx*) bad "ctx should be absent: $out";; *) ok "no ctx part without context_window";; esac
out=$(run "$(j - 1 5 s)")
case "$out" in 'Claude | '*) ok "model falls back to Claude";; *) bad "model fallback: $out";; esac

# 6. budget from the environment
newdata
eq "KIT_BUDGET_USD=100" 'Sonnet 5.5 | session $1.42 | month $1 / $100 (pace $53) | ctx 38%' "$(run "$SONNET" KIT_BUDGET_USD=100)"

# 7. leap year: 29 of 29 days -> pace = budget
newdata
out=$(run "$SONNET" KIT_TODAY=2028-02-29 KIT_BUDGET_USD=290)
case "$out" in *'/ $290 (pace $290)'*) ok "leap year pace 290";; *) bad "leap: $out";; esac

# 8. colour (NO_COLOR= is empty, which means colour on); pace on 11-16 of 30 with budget 100 is 53
ESC=$(printf '\033')
newdata
out=$(run "$(j M 10 - c1)" NO_COLOR= KIT_BUDGET_USD=100)
case "$out" in *"${ESC}[32mmonth \$10 / \$100 (pace \$53)${ESC}[0m"*) ok "under pace is green (32)";; *) bad "green: $out";; esac
newdata
out=$(run "$(j M 60 - c1)" NO_COLOR= KIT_BUDGET_USD=100)
case "$out" in *"${ESC}[33mmonth"*) ok "over pace, under 90% is yellow (33)";; *) bad "yellow: $out";; esac
newdata
out=$(run "$(j M 90 - c1)" NO_COLOR= KIT_BUDGET_USD=100)
case "$out" in *"${ESC}[31mmonth"*) ok "90% of budget is red (31)";; *) bad "red: $out";; esac
out=$(run "$(j M 95 - c1)" NO_COLOR=1 KIT_BUDGET_USD=100)
case "$out" in *"$ESC"*) bad "NO_COLOR=1 still has an escape";; *) ok "NO_COLOR=1 has no escape";; esac

# 9. Windows mode with a CRLF-writing fake jq
newdata
mkdir -p "$TMP/fakebin"
cat >"$TMP/fakebin/jq" <<EOF
#!/usr/bin/env bash
case " \$* " in *" -b "*) exec "$REAL_JQ" "\$@";; esac
"$REAL_JQ" "\$@" | while IFS= read -r l; do printf '%s\r\n' "\$l"; done
EOF
chmod +x "$TMP/fakebin/jq"
out=$(printf '%s' "$(j "Sonnet 5.5" 1.42 38.4 s1)" | env PATH="$TMP/fakebin:$PATH" KIT_OS=windows XDG_DATA_HOME="$DATA" NO_COLOR=1 KIT_TODAY=2026-11-16 bash "$SCRIPT" 2>/dev/null)
eq "windows mode line" 'Sonnet 5.5 | session $1.42 | month $1 / $250 (pace $133) | ctx 38%' "$out"
case "$out" in *$'\r'*) bad "CR in output";; *) ok "no CR in output";; esac
names=$(cd "$DATA/claude-kit/spend/2026-11" && printf '%s|' *)
case "$names" in *$'\r'*) bad "CR in ledger file name";; *) ok "no CR in ledger file name ($names)";; esac

# 9b. ctx in tokens: ctx <N>k, N = tokens / 1000 rounded half up; colour by size
newdata
eq "tokens 84000" 'Sonnet 5.5 | session $1.42 | month $1 / $250 (pace $133) | ctx 84k' "$(run "$(j "Sonnet 5.5" 1.42 - s1 84000)")"
out=$(run "$(j M 1 - s 84499)"); case "$out" in *'| ctx 84k') ok "84499 -> 84k";; *) bad "84499: $out";; esac
out=$(run "$(j M 1 - s 84500)"); case "$out" in *'| ctx 85k') ok "84500 -> 85k";; *) bad "84500: $out";; esac
out=$(run "$(j M 1 - s 0)");     case "$out" in *'| ctx 0k') ok "0 -> 0k";; *) bad "0: $out";; esac
out=$(run "$(j M 1 - s 999)");   case "$out" in *'| ctx 1k') ok "999 -> 1k";; *) bad "999: $out";; esac
out=$(run "$(j M 1 - s 99999)" NO_COLOR=)
case "$out" in *"${ESC}[32mctx 100k${ESC}[0m") ok "99999 is green (32)";; *) bad "99999: $out";; esac
out=$(run "$(j M 1 - s 100000)" NO_COLOR=)
case "$out" in *"${ESC}[33mctx 100k${ESC}[0m") ok "100000 is yellow (33)";; *) bad "100000: $out";; esac
out=$(run "$(j M 1 - s 149999)" NO_COLOR=)
case "$out" in *"${ESC}[33mctx 150k${ESC}[0m") ok "149999 is yellow (33)";; *) bad "149999: $out";; esac
out=$(run "$(j M 1 - s 150000)" NO_COLOR=)
case "$out" in *"${ESC}[31mctx 150k${ESC}[0m") ok "150000 is red (31)";; *) bad "150000: $out";; esac
out=$(run "$(j M 1 - s 84000)")
case "$out" in *"$ESC"*) bad "NO_COLOR ctx has an escape";; *) ok "NO_COLOR ctx has no escape";; esac
out=$(run "$(j M 1 38.4 s 84000)"); case "$out" in *'| ctx 84k') ok "tokens win over percentage";; *) bad "both: $out";; esac
out=$(run "$(j M 1 38.4 s '"abc"')"); case "$out" in *'| ctx 38%') ok "non-number tokens fall back to percentage";; *) bad "nan: $out";; esac
out=$(printf '%s' "$(j M 1 - s 84000)" | env PATH="$TMP/fakebin:$PATH" KIT_OS=windows XDG_DATA_HOME="$DATA" NO_COLOR=1 KIT_TODAY=2026-11-16 bash "$SCRIPT" 2>/dev/null)
case "$out" in *'| ctx 84k') ok "windows mode tokens";; *) bad "windows tokens: $out";; esac
case "$out" in *$'\r'*) bad "CR in tokens output";; *) ok "no CR in tokens output";; esac

# 10. garbage and empty stdin
newdata
for in in 'not json {{' ''; do
  out=$(printf '%s' "$in" | env XDG_DATA_HOME="$DATA" NO_COLOR=1 KIT_TODAY=2026-11-16 bash "$SCRIPT" 2>"$TMP/err"); rc=$?
  lines=$(printf '%s\n' "$out" | wc -l)
  if [ "$rc" -eq 0 ] && [ "$lines" -eq 1 ] && [ ! -s "$TMP/err" ]; then ok "bad stdin [$in]: exit 0, one line, no stderr ($out)"; else bad "bad stdin [$in]: rc=$rc lines=$lines"; fi
done

# 11. hostile session id stays inside the month directory
newdata
run "$(j M 1 - '../../evil/..')" >/dev/null
run "$(j M 1 - '/etc/x')" >/dev/null
outside=$(cd "$DATA" && find . -type f -not -path './claude-kit/spend/2026-11/*' | wc -l)
inside=$(cd "$DATA/claude-kit/spend/2026-11" && printf '%s|' *)
if [ "$outside" -eq 0 ] && [ ! -e "$DATA/claude-kit/evil" ]; then ok "hostile ids stay in the month dir ($inside)"; else bad "file outside month dir"; fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
