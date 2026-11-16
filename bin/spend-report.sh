#!/usr/bin/env bash
# Where did Claude Code money go? Reads the session transcripts on this machine, costs no tokens.
#   spend-report.sh [days]      (default 7; a non-number means 7)
# Reads ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/**/*.jsonl modified in the last <days> days.
# A file under a subagents directory is a subagent file, every other file is a main session.
# Only usage numbers, times and ids are read, never message text. Prices are list prices.
# Env: CLAUDE_CONFIG_DIR, KIT_OS (override OSTYPE for the Windows jq fix: jq -b, CR stripped in awk).
# One find, one jq, one awk. Never fails loudly: exit 0 always.

set -u
exec 2>/dev/null

days=${1:-7}
[[ $days =~ ^[0-9]+$ ]] && days=$((10#$days)) || days=7
[ "$days" -gt 0 ] || days=7

dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects
if [ ! -d "$dir" ] || [ -z "$(find "$dir" -type f -name '*.jsonl' -mtime "-$days" -print -quit)" ]; then
  printf 'spend report: no session files in the last %s days\n' "$days"
  exit 0
fi

# Windows: jq must run with -b (no CRLF). A shell function is not visible to xargs, so an array.
JQ=(jq)
win=0
case "${KIT_OS:-${OSTYPE:-}}" in msys*|cygwin*|windows) JQ=(jq -b); win=1 ;; esac

IFS= read -r -d '' jqprog <<'EOF'
def ts: ((.timestamp // "") | sub("\\.[0-9]+Z$";"Z") | (try fromdateiso8601 catch 0));
(fromjson? // empty)
| if .type=="assistant" and ((.message.usage|type)=="object") then
    [ "A", input_filename, ts, (.message.id//""), (.message.model//""),
      (.message.usage.input_tokens//0), (.message.usage.cache_creation_input_tokens//0),
      (.message.usage.cache_read_input_tokens//0), (.message.usage.output_tokens//0),
      (.message.usage.cache_creation.ephemeral_1h_input_tokens//0),
      (.message.usage.cache_creation.ephemeral_5m_input_tokens//0) ] | @tsv
  elif .type=="user" and (.isMeta != true) then
    [ "U", input_filename, ts,
      (if (.message.content|type)=="string" then 1
       elif (.message.content|type)=="array" then (if any(.message.content[]; .type=="tool_result") then 0 else 1 end)
       else 0 end) ] | @tsv
  else empty end
EOF

IFS= read -r -d '' awkprog <<'EOF'
# list prices 2026-11, USD per million input tokens; Bedrock and Vertex have their own lists
function pin(m) {
  if (m ~ /fable-5-2|mythos-5-2/) return 8
  if (m ~ /fable|mythos/) return 10
  if (m ~ /opus-5-5/) return 4
  if (m ~ /opus/) return 5
  if (m ~ /sonnet-5/) return 2
  if (m ~ /sonnet/) return 3
  if (m ~ /haiku-5-5/) return 0.1
  if (m ~ /haiku/) return 1
  return 0
}
function rmul(m) {
  if (m ~ /fable-5-[12]|mythos-5-[12]/) return 0.025
  if (m ~ /opus-5-5|sonnet-5-5/) return 0.05
  return 0.1
}
function fam(m) {
  if (m ~ /fable|mythos/) return "fable"
  if (m ~ /opus/) return "opus"
  if (m ~ /sonnet/) return "sonnet"
  if (m ~ /haiku/) return "haiku"
  return "unknown"
}
BEGIN { FS = "\t" }
{ if (win) sub(/\r$/, "") }
$1 == "A" {
  k = $2 SUBSEP $4
  if ($4 != "" && (k in idx)) i = idx[k]
  else { i = ++n; if ($4 != "") idx[k] = i }
  T[i] = "A"; F[i] = $2; TS[i] = $3 + 0; M[i] = $5
  INP[i] = $6 + 0; CC[i] = $7 + 0; CR[i] = $8 + 0; OUT[i] = $9 + 0; C1[i] = $10 + 0; C5[i] = $11 + 0
  next
}
$1 == "U" { i = ++n; T[i] = "U"; F[i] = $2; FL[i] = $4 + 0 }
END {
  nk = split("main sub", kinds, " ")
  nf = split("fable opus sonnet haiku unknown", fams, " ")
  for (i = 1; i <= n; i++) {
    f = F[i]
    if (T[i] == "U") { if (FL[i] == 1) hs[f] = 1; continue }
    m = M[i]
    if (m == "<synthetic>") continue
    pr = pin(m); unk = (pr == 0)
    if (unk) { pr = 2; rm = 0.05 } else rm = rmul(m)
    fm = fam(m)
    c1 = C1[i]; c5 = C5[i]
    if (c1 + c5 == 0) c5 = CC[i]
    p = pr / 1e6
    w = p * (2 * c1 + 1.25 * c5); r = p * rm * CR[i]; o = p * 5 * OUT[i]
    tot = w + r + o + p * INP[i]
    issub = (f ~ /[\/\\]subagents[\/\\]/)
    kind = issub ? "sub" : "main"
    key = kind SUBSEP fm
    rq[key]++; tt[key] += tot; tw[key] += w; tr[key] += r; to[key] += o
    total += tot
    if (unk) unkn++
    if (issub) continue
    mtot += tot
    ps = INP[i] + CC[i] + CR[i]
    b = (ps < 50000) ? 1 : (ps < 100000) ? 2 : (ps < 200000) ? 3 : 4
    pbn[b]++; pbt[b] += tot
    fcost[f] += tot
    sc1 += c1
    x1 += p * 0.75 * c1
    if ((f in prev) && prev[f] > 0 && TS[i] > 0) {
      g = TS[i] - prev[f]
      cl = (g < 300) ? 1 : (g < 3600) ? 2 : 3
      gn[cl]++; ga[cl] += (hs[f] ? 1 : 0)
      if (cl == 2) { y1 += p * (1.25 - rm) * CR[i]; crs += CR[i]; pss += ps }
      if (cl == 3) w3 += w
    }
    prev[f] = TS[i]; hs[f] = 0
  }
  printf "spend report: last %s days, list price, this machine\n", days
  printf "%-4s %-10s%8s%10s%10s%10s%10s\n", "kind", "model", "requests", "$total", "$write", "$read", "$output"
  for (a = 1; a <= nk; a++) for (b = 1; b <= nf; b++) {
    key = kinds[a] SUBSEP fams[b]
    if (rq[key] > 0)
      printf "%-4s %-10s%8d%10.2f%10.2f%10.2f%10.2f\n", kinds[a], fams[b], rq[key], tt[key], tw[key], tr[key], to[key]
  }
  printf "total $%.2f\n", total
  printf "%-11s%12s%10s%8s\n", "prompt size", "requests", "$total", "share"
  split("under 50k|50-100k|100-200k|over 200k", pl, "|")
  for (b = 1; b <= 4; b++)
    printf "%-11s%12d%10.2f%7.0f%%\n", pl[b], pbn[b], pbt[b], (mtot > 0) ? 100 * pbt[b] / mtot : 0
  printf "%-11s%12s   %s\n", "gap", "requests", "after your message"
  split("under 5 min|5-60 min|over 60 min", gl, "|")
  for (b = 1; b <= 3; b++) printf "%-11s%12d   %d\n", gl[b], gn[b], ga[b]
  nn = (pss > 0) ? 100 * crs / pss : 0
  if (sc1 == 0)
    printf "1-hour cache: no 1-hour writes reported. After a 5-60 min gap %.0f%% of the prompt came from the cache.\n", nn
  else
    printf "1-hour cache: extra write cost $%.2f, re-sends avoided $%.2f: %s. After a 5-60 min gap %.0f%% of the prompt came from the cache.\n", x1, y1, (y1 > x1) ? "pays" : "does not pay", nn
  printf "back after more than 60 min: %d times, $%.2f in total, $%.2f each\n", gn[3], w3, (gn[3] > 0) ? w3 / gn[3] : 0
  for (f in fcost) {
    v = fcost[f]
    s = (v < 1) ? 1 : (v < 5) ? 2 : (v < 20) ? 3 : 4
    sn[s]++; sv[s] += v
  }
  printf "sessions by cost: under $1: %d ($%.2f) | $1-5: %d ($%.2f) | $5-20: %d ($%.2f) | over $20: %d ($%.2f)\n", sn[1], sv[1], sn[2], sv[2], sn[3], sv[3], sn[4], sv[4]
  if (unkn > 0) printf "unknown model id (priced as Sonnet): %d requests\n", unkn
}
EOF

find "$dir" -type f -name '*.jsonl' -mtime "-$days" -print0 \
  | xargs -0 "${JQ[@]}" -R -r "$jqprog" 2>/dev/null \
  | awk -v days="$days" -v win="$win" "$awkprog"
exit 0
