#!/usr/bin/env bash
# Claude Code status line: model | session cost | month spend vs budget (with pace) | context size.
#   Sonnet 5.5 | session $1.42 | month $86 / $250 (pace $133) | ctx 84k
# ctx is the last prompt in tokens (green < 100k, yellow from 100k, red from 150k); without
#   token data it falls back to the plain used percentage (ctx 38%, no colour).
# Ledger: ${XDG_DATA_HOME:-$HOME/.local/share}/claude-kit/spend/<YYYY-MM>/<session id>, one file
#   per session holding "base last" (base absorbs the cost lost when /clear resets it).
# Env: KIT_BUDGET_USD (default 250), KIT_TODAY (YYYY-MM-DD, default today), NO_COLOR (no ANSI),
#   KIT_OS (override OSTYPE for the Windows jq CRLF fix).
# The figure is Claude Code's local estimate at list price, for this machine only.
# Never fails loudly: on any problem it prints the model name (or Claude) and exits 0.
# Processes per run: one jq, one awk, plus mkdir -p only when the month directory is missing
# (date is a bash builtin; the external date is only a fallback for bash < 4.2).

set -u
exec 2>/dev/null

case "${KIT_OS:-${OSTYPE:-}}" in msys*|cygwin*|windows) jq() { command jq -b "$@"; } ;; esac

model=Claude
in=
IFS= read -r -d '' in
out=$(jq -r '(.model.display_name // ""), (.cost.total_cost_usd // ""), (.context_window.used_percentage // ""), (.context_window.total_input_tokens // ""), (.session_id // "")' <<<"$in") || out=
out=${out//$'\r'/}
if [ -n "$out" ]; then
  { IFS= read -r m; IFS= read -r cost; IFS= read -r ctx; IFS= read -r tok; IFS= read -r sid; } <<<"$out"
  [ -n "${m:-}" ] && model=$m
else
  printf '%s\n' "$model"
  exit 0
fi

num='^[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$'
[[ ${cost:-} =~ $num ]] || cost=
[[ ${ctx:-} =~ $num ]] || ctx=
[[ ${tok:-} =~ $num ]] || tok=
budget=${KIT_BUDGET_USD:-250}
[[ $budget =~ $num ]] || budget=250

today=${KIT_TODAY:-}
[[ $today =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { printf -v today '%(%Y-%m-%d)T' -1 || today=; }
[[ $today =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || today=$(date +%F)

sid=${sid:-}
sid=${sid//[^A-Za-z0-9_-]/}
[ -n "$sid" ] || sid=default

dir=${XDG_DATA_HOME:-$HOME/.local/share}/claude-kit/spend/${today:0:7}
[ -d "$dir" ] || mkdir -p "$dir"

shopt -s nullglob
files=("$dir"/*)

nocolor=0
[ -n "${NO_COLOR:-}" ] && nocolor=1

line=$(KIT_CUR="$dir/$sid" KIT_MODEL="$model" awk \
  -v c="$cost" -v ctx="$ctx" -v tok="$tok" -v budget="$budget" -v today="$today" -v nocolor="$nocolor" '
FNR == 1 {
  b = $1 + 0; l = $2 + 0
  if (FILENAME == ENVIRON["KIT_CUR"]) {
    found = 1
    # /clear reset: bank the old cost. The margin is above the rounding of the stored value,
    # so an unchanged cost with many decimals is never taken for a reset.
    if (c != "") { if (c + 0.000002 < l) b += l; l = c + 0 }
    nb = b; nl = l; sess = l
  }
  total += b + l
}
END {
  cur = ENVIRON["KIT_CUR"]
  if (!found) { nb = 0; nl = (c != "") ? c + 0 : 0; sess = nl; total += nl }
  split(today, d, "-"); y = d[1] + 0; m = d[2] + 0; dd = d[3] + 0
  if (m == 2) dim = ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) ? 29 : 28
  else if (m == 4 || m == 6 || m == 9 || m == 11) dim = 30
  else dim = 31
  pace = budget * dd / dim
  # Rounding: half up (int(x + 0.5)), so 5.50 -> 6 and 5.49 -> 5.
  seg = sprintf("month $%d / $%d (pace $%d)", int(total + 0.5), int(budget + 0.5), int(pace + 0.5))
  if (!nocolor) {
    col = (total >= 0.9 * budget) ? 31 : (total > pace ? 33 : 32)
    seg = sprintf("%c[%dm%s%c[0m", 27, col, seg, 27)
  }
  s = sprintf("%s | session $%.2f | %s", ENVIRON["KIT_MODEL"], sess, seg)
  if (tok != "") {
    cs = sprintf("ctx %dk", int(tok / 1000 + 0.5))
    if (!nocolor) cs = sprintf("%c[%dm%s%c[0m", 27, (tok >= 150000 ? 31 : (tok >= 100000 ? 33 : 32)), cs, 27)
    s = s " | " cs
  } else if (ctx != "") s = s sprintf(" | ctx %d%%", int(ctx + 0.5))
  print s
  fflush()
  if (c != "") { printf "%.6f %.6f\n", nb, nl > cur; close(cur) }
  exit 0
}' /dev/null "${files[@]}") || line=

if [ -n "$line" ]; then printf '%s\n' "$line"; else printf '%s\n' "$model"; fi
exit 0
