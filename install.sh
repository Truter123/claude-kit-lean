#!/usr/bin/env bash
# claude-kit installer: code-navigator jar, kit agents, rules, hooks, budget settings, status line.
# Linux, WSL and Windows Git Bash. RTK only with --with-rtk.
# Safe to run twice. Never runs sudo. See --help.

set -euo pipefail

# Windows mode (Git Bash): KIT_OS=windows, or KIT_OS unset and uname says MINGW/MSYS/CYGWIN.
case "${KIT_OS:-}" in
  windows) WIN=1 ;;
  linux) WIN=0 ;;
  *) case "$(uname -s 2>/dev/null || true)" in MINGW*|MSYS*|CYGWIN*) WIN=1 ;; *) WIN=0 ;; esac ;;
esac
# jq.exe writes CRLF unless called with -b.
if [ "$WIN" -eq 1 ]; then jq() { command jq -b "$@"; }; fi
# native <path>: the Windows form (C:/Users/...) in Windows mode, else the path unchanged.
native() { if [ "$WIN" -eq 1 ]; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

CG_REPO="${CG_REPO:-https://github.com/Truter123/code-navigator}"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STATE="$CFG/.claude-kit-state"
# CG_REF: the environment variable, else the one saved in the state file, else master.
if [ -z "${CG_REF:-}" ]; then
  CG_REF=$(sed -n 's/^cg_ref=//p' "$STATE" 2>/dev/null | head -n 1) || true
fi
CG_REF="${CG_REF:-master}"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/claude-kit"
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAR="$DATA/code-navigator/jars/code-navigator.jar"
RTK_INSTALLER_URL="https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh"
SETTINGS="$CFG/settings.json"
BUDGET="$KIT/settings/budget.json"

usage() {
  cat <<'EOF'
Usage: install.sh [--check] [--uninstall] [--with-rtk] [--no-rtk] [--help]
  --check      print one [ok] or [--] line per item; exit 0 only when all are [ok]
  --uninstall  remove the installed kit files, the @KIT.md line, the kit hooks and the kit status line
               (the other budget settings stay; RTK stays)
  --with-rtk   also run the RTK step (needs curl and python3); off by default
               (with --check: also check the RTK item; without it there is no RTK line)
  --no-rtk     accepted and does nothing (RTK is already off by default)
  --help       this text
Environment:
  CG_REPO  code-navigator git URL (default https://github.com/Truter123/code-navigator)
  CG_REF   branch or tag to install. Order: the CG_REF variable when set, else the
           cg_ref= line saved in <config dir>/.claude-kit-state by the last run, else master.
           The value used is saved there, so an update run without CG_REF keeps the ref.
  KIT_OS   windows or linux: force Windows (Git Bash) mode on or off. Test override;
           unset means detect from uname (MINGW*, MSYS*, CYGWIN* = Windows).
Also honoured: CLAUDE_CONFIG_DIR, XDG_DATA_HOME, XDG_CONFIG_HOME.
EOF
}

die() { printf 'claude-kit: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------- step 1: tools

# Prints the major version of `java`, or nothing when java is missing.
java_major() {
  local v major
  command -v java >/dev/null 2>&1 || return 0
  v=$(java -version 2>&1 | sed -n '1s/.*version "\([^"]*\)".*/\1/p') || true
  [ -n "$v" ] || return 0
  major=${v%%[.-]*}
  if [ "$major" = "1" ]; then v=${v#1.}; major=${v%%[.-]*}; fi
  printf '%s' "$major"
}

# True when `git` is 2.31 or newer.
git_new_enough() {
  local v maj min
  v=$(git --version 2>/dev/null | sed -n 's/^git version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p') || true
  [ -n "$v" ] || return 1
  read -r maj min <<<"$v"
  [ "$maj" -gt 2 ] || { [ "$maj" -eq 2 ] && [ "$min" -ge 31 ]; }
}

check_tools_windows() {
  local bad=0 jm up
  if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
    up=$(cygpath -u "$USERPROFILE" 2>/dev/null || true)
    if [ -n "$up" ] && [ "$up" != "$HOME" ]; then
      say "warning: Claude Code reads %USERPROFILE%\\.claude, but this script writes to $CFG"
    fi
  fi
  if ! command -v git >/dev/null 2>&1 || ! git_new_enough; then
    say "winget install --id Git.Git -e"; bad=1
  fi
  if ! command -v jq >/dev/null 2>&1; then say "winget install --id jqlang.jq -e"; bad=1; fi
  jm=$(java_major)
  if [ -z "$jm" ] || ! [ "$jm" -ge 21 ] 2>/dev/null; then
    say "winget install --id EclipseAdoptium.Temurin.21.JRE -e"; bad=1
  fi
  if [ "$bad" -eq 1 ]; then
    say "Close and reopen Git Bash, then run this script again."
    exit 1
  fi
}

check_tools() {
  local with_rtk=${1:-0} pkgs=() jm
  if [ "$WIN" -eq 1 ]; then check_tools_windows; return 0; fi
  command -v git >/dev/null 2>&1 || pkgs+=(git)
  if command -v git >/dev/null 2>&1 && ! git_new_enough; then pkgs+=(git); fi
  if [ "$with_rtk" -eq 1 ]; then command -v curl >/dev/null 2>&1 || pkgs+=(curl); fi
  command -v jq >/dev/null 2>&1 || pkgs+=(jq)
  if [ "$with_rtk" -eq 1 ]; then command -v python3 >/dev/null 2>&1 || pkgs+=(python3); fi
  jm=$(java_major)
  if [ -z "$jm" ] || ! [ "$jm" -ge 21 ] 2>/dev/null; then pkgs+=(openjdk-21-jre-headless); fi
  if [ "${#pkgs[@]}" -gt 0 ]; then
    # one line, no duplicates
    if [ "$with_rtk" -eq 1 ]; then
      printf 'claude-kit: missing or too old (git 2.31+, curl, jq, python3, java 21+). Run:\n' >&2
    else
      printf 'claude-kit: missing or too old (git 2.31+, jq, java 21+). Run:\n' >&2
    fi
    printf 'sudo apt install -y %s\n' "$(printf '%s\n' "${pkgs[@]}" | awk '!s[$0]++' | tr '\n' ' ' | sed 's/ $//')" >&2
    exit 1
  fi
  case "$KIT" in
    /mnt/*) say "warning: the kit is under /mnt/ (a Windows drive). SQLite there is slow; clone it under your Linux home." ;;
  esac
}

# --------------------------------------------------------- step 2: code-navigator

install_code_navigator() {
  mkdir -p "$DATA"
  if [ -d "$DATA/code-navigator/.git" ]; then
    git -C "$DATA/code-navigator" fetch --depth 1 origin "$CG_REF"
    git -C "$DATA/code-navigator" reset --hard FETCH_HEAD
  else
    git clone --depth 1 --branch "$CG_REF" "$CG_REPO" "$DATA/code-navigator"
  fi
  [ -f "$JAR" ] || die "jar missing after clone: $JAR (is it committed on $CG_REF of $CG_REPO?)"
}

# ------------------------------------------------------ steps 3-4: copies, rules

INSTALLED=()

state_lists() { [ -f "$STATE" ] && grep -qxF "file=$1" "$STATE"; }

# install_file <src> <dest>: copy. A symlink in the way is removed; a foreign regular file
# (differs, not in the state file) becomes <dest>.bak-kit unless that backup already exists.
install_file() {
  local src=$1 dest=$2
  mkdir -p "$(dirname "$dest")"
  INSTALLED+=("$dest")
  if [ -L "$dest" ]; then
    rm -f "$dest"
  elif [ -f "$dest" ] && ! cmp -s "$src" "$dest" && ! state_lists "$dest" && [ ! -e "$dest.bak-kit" ]; then
    mv -f "$dest" "$dest.bak-kit"
  fi
  cmp -s "$src" "$dest" 2>/dev/null || cp "$src" "$dest"
}

install_files() {
  local f
  for f in "$KIT"/agents/*.md; do
    install_file "$f" "$CFG/agents/$(basename "$f")"
  done
  install_file "$KIT/KIT.md" "$CFG/KIT.md"
  if ! grep -qxF '@KIT.md' "$CFG/CLAUDE.md" 2>/dev/null; then
    mkdir -p "$CFG"
    if [ -s "$CFG/CLAUDE.md" ] && [ -n "$(tail -c1 "$CFG/CLAUDE.md")" ]; then printf '\n' >> "$CFG/CLAUDE.md"; fi
    printf '@KIT.md\n' >> "$CFG/CLAUDE.md"
  fi
}

write_state() {
  local tmp f
  tmp=$(mktemp)
  printf 'cg_ref=%s\n' "$CG_REF" > "$tmp"
  for f in "${INSTALLED[@]}"; do printf 'file=%s\n' "$f" >> "$tmp"; done
  cmp -s "$tmp" "$STATE" 2>/dev/null || cat "$tmp" > "$STATE"
  rm -f "$tmp"
}

# ------------------------------------------------------------------ step 5: hooks

# The kit hook entries as a JSON array of {event,label,entry}. $PWD and $HOME in the
# commands are literal text for the hook's shell.
entries_json() {
  local kit_n jar_n proj='"$PWD"'
  kit_n=$(native "$KIT"); jar_n=$(native "$JAR")
  if [ "$WIN" -eq 1 ]; then proj='"$(pwd -W)"'; fi
  jq -nc --arg kit "$kit_n" --arg jar "$jar_n" --arg proj "$proj" '[
    {event:"PreToolUse", label:"agent-guard.sh", entry:{matcher:"Agent", hooks:[{type:"command", command:("bash \"" + $kit + "/hooks/agent-guard.sh\""), statusMessage:"claude-kit: checking spawn"}]}},
    {event:"PreToolUse", label:"budget-guard.sh", entry:{matcher:"*", hooks:[{type:"command", command:("bash \"" + $kit + "/hooks/budget-guard.sh\"")}]}},
    (("SubagentStart","SubagentStop","SessionEnd") as $e
      | {event:$e, label:"agent-registry.sh", entry:{hooks:[{type:"command", command:("bash \"" + $kit + "/hooks/agent-registry.sh\"")}]}}),
    {event:"SessionStart", label:"cg-sync.sh", entry:{hooks:[{type:"command", command:("bash \"" + $kit + "/hooks/cg-sync.sh\" \"$PWD\""), statusMessage:"code-navigator: refreshing index", async:true}]}},
    {event:"PostToolUse", label:"mark-dirty", entry:{matcher:"Edit|Write|MultiEdit|NotebookEdit", hooks:[{type:"command", command:("[ \"$PWD\" != \"$HOME\" ] && [ -f \"$PWD/navigators/code/code-navigator.db\" ] && java -jar \"" + $jar + "\" mark-dirty " + $proj + "; true"), statusMessage:"code-navigator: marking index dirty", async:true}]}},
    {event:"Stop", label:"sync-if-dirty", entry:{matcher:"", hooks:[{type:"command", command:("[ \"$PWD\" != \"$HOME\" ] && [ -f \"$PWD/navigators/code/.dirty\" ] && timeout 600 java -jar \"" + $jar + "\" sync-if-dirty " + $proj + "; true"), statusMessage:"code-navigator: syncing index", async:true}]}}
  ]'
}

# write_if_changed <file> <new content file>: replace only when the JSON differs.
write_if_changed() {
  local file=$1 new=$2
  if [ -f "$file" ] && [ "$(jq -S -c . "$file")" = "$(jq -S -c . "$new")" ]; then return 0; fi
  cat "$new" > "$file"
}

install_hooks() {
  local tmp
  mkdir -p "$CFG"
  if [ ! -f "$SETTINGS" ]; then
    printf '{}\n' > "$SETTINGS"
  fi
  if [ ! -e "$SETTINGS.bak-kit" ]; then
    cp -p "$SETTINGS" "$SETTINGS.bak-kit"
  fi
  tmp=$(mktemp)
  jq --argjson entries "$(entries_json)" '
    .hooks //= {}
    | reduce $entries[] as $x (.;
        .hooks[$x.event] = (
          (.hooks[$x.event] // []) as $cur
          | if any($cur[]; any(.hooks[]?; .command == $x.entry.hooks[0].command))
            then $cur else $cur + [$x.entry] end))
  ' "$SETTINGS" > "$tmp"
  write_if_changed "$SETTINGS" "$tmp"
  rm -f "$tmp"
}

uninstall_hooks() {
  local tmp
  [ -f "$SETTINGS" ] || return 0
  tmp=$(mktemp)
  jq --arg kit "$KIT/" --arg data "$DATA/" --arg kitn "$(native "$KIT")/" --arg datan "$(native "$DATA")/" '
    if (.hooks | type) == "object" then
      .hooks |= (
        with_entries(
          .value |= (
            map(.hooks = ((.hooks // []) | map(select(((.command // "") | (contains($kit) or contains($data) or contains($kitn) or contains($datan))) | not))))
            | map(select((.hooks | length) > 0))))
        | with_entries(select((.value | length) > 0)))
      | if .hooks == {} then del(.hooks) else . end
    else . end
  ' "$SETTINGS" > "$tmp"
  write_if_changed "$SETTINGS" "$tmp"
  rm -f "$tmp"
}

# ------------------------------------------------------- step 5b: budget profile

# statusline_cmd: the status-line command, the kit path in the same form as the hook commands.
statusline_cmd() { printf 'bash "%s/bin/statusline.sh"' "$(native "$KIT")"; }

# jq prelude: needs --argjson B <budget.json>. report: one {n,p} per key of budget.json
# (top-level scalars, env.<key>, permissions.deny), p = already present in the input settings.
BUDGET_JQ='
def report:
  . as $s
  | [ ($B | keys_unsorted[] | select(. != "env" and . != "permissions")) as $k
      | {n: $k, p: ($s | has($k))} ]
  + [ (($B.env // {}) | keys_unsorted[]) as $k
      | {n: ("env." + $k), p: ((($s.env | type) == "object") and ($s.env | has($k)))} ]
  + ( (($B.permissions // {}).deny // []) as $d
      | (($s.permissions | objects | .deny) // []) as $c
      | if ($d | length) > 0
        then [{n: "permissions.deny", p: all($d[]; . as $x | any($c[]; . == $x))}]
        else [] end );
'

BUDGET_ADDED=nothing
BUDGET_KEPT=nothing

install_budget() {
  local tmp bj sl rep
  [ -f "$BUDGET" ] || die "budget profile missing: $BUDGET"
  bj=$(jq -c . "$BUDGET")
  sl=$(statusline_cmd)
  rep=$(jq -c --argjson B "$bj" "$BUDGET_JQ"'
    report + [{n: "statusLine", p: has("statusLine")}]
    | {added: [.[] | select(.p | not) | .n], kept: [.[] | select(.p) | .n]}
    | .added |= (if length == 0 then "nothing" else join(", ") end)
    | .kept |= (if length == 0 then "nothing" else join(", ") end)' "$SETTINGS")
  BUDGET_ADDED=$(jq -r '.added' <<<"$rep")
  BUDGET_KEPT=$(jq -r '.kept' <<<"$rep")
  tmp=$(mktemp)
  jq --argjson B "$bj" --arg cmd "$sl" '
    reduce ($B | keys_unsorted[] | select(. != "env" and . != "permissions")) as $k (.;
      if has($k) then . else .[$k] = $B[$k] end)
    | reduce (($B.env // {}) | keys_unsorted[]) as $k (.;
        if ((.env | type) == "object") and (.env | has($k)) then . else .env[$k] = $B.env[$k] end)
    | ((($B.permissions // {}).deny // []) as $d
        | if ($d | length) == 0 then .
          else .permissions.deny = reduce $d[] as $x ((.permissions.deny // []);
                 . as $c | if any($c[]; . == $x) then $c else $c + [$x] end)
          end)
    | if has("statusLine") then . else .statusLine = {type: "command", command: $cmd} end
  ' "$SETTINGS" > "$tmp"
  write_if_changed "$SETTINGS" "$tmp"
  rm -f "$tmp"
}

# budget_present: the names of the budget.json keys present in settings.json, one per line.
budget_present() {
  [ -f "$SETTINGS" ] || return 0
  jq -r --argjson B "$(jq -c . "$BUDGET")" "$BUDGET_JQ"'report | .[] | select(.p) | .n' "$SETTINGS"
}

# ------------------------------------------------------------------ step 6: RTK

# rtk_set_toml <config.toml>: exclude_commands = ["git diff"], [awareness] level = "full",
# [telemetry] enabled = false. Section-aware; adds a missing section or key. Idempotent.
rtk_set_toml() {
  mkdir -p "$(dirname "$1")"
  python3 -I - "$1" <<'PY'
import os, re, sys

path = sys.argv[1]
lines = open(path).read().split("\n") if os.path.exists(path) else []
if lines and lines[-1] == "":
    lines.pop()

wanted = [
    ("hooks", "exclude_commands", '["git diff"]'),
    ("awareness", "level", '"full"'),
    ("telemetry", "enabled", "false"),
]

def section_range(section):
    start = None
    for i, line in enumerate(lines):
        if re.match(r"^\s*\[" + re.escape(section) + r"\]\s*(#.*)?$", line):
            start = i
            break
    if start is None:
        return None
    end = len(lines)
    for j in range(start + 1, len(lines)):
        if re.match(r"^\s*\[", lines[j]):
            end = j
            break
    return start, end

for section, key, value in wanted:
    rng = section_range(section)
    if rng is None:
        if lines and lines[-1].strip() != "":
            lines.append("")
        lines += ["[" + section + "]", key + " = " + value]
        continue
    start, end = rng
    new = key + " = " + value
    idx = None
    for i in range(start + 1, end):
        if re.match(r"^\s*" + re.escape(key) + r"\s*=", lines[i]):
            idx = i
            break
    if idx is None:
        lines.insert(start + 1, new)
        continue
    stop = idx
    if "[" in lines[idx].split("=", 1)[1] and "]" not in lines[idx].split("=", 1)[1]:
        while stop < end - 1 and "]" not in lines[stop]:
            stop += 1
    lines[idx:stop + 1] = [new]

with open(path, "w") as f:
    f.write("\n".join(lines) + "\n")
PY
}

install_rtk() {
  local orig_path=$PATH
  if ! command -v rtk >/dev/null 2>&1; then
    say "rtk: running the official installer from $RTK_INSTALLER_URL (installs to ~/.local/bin)"
    curl -fsSL "$RTK_INSTALLER_URL" | sh
  fi
  PATH="$HOME/.local/bin:$PATH"
  command -v rtk >/dev/null 2>&1 || die "rtk not found after its installer ran"
  rtk init -g --auto-patch
  rtk_set_toml "${XDG_CONFIG_HOME:-$HOME/.config}/rtk/config.toml"
  rtk init -g --auto-patch
  case ":$orig_path:" in
    *":$HOME/.local/bin:"*) ;;
    *) say "hint: add ~/.local/bin to PATH:  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc" ;;
  esac
}

# ------------------------------------------------------------------- --check

CHECK_BAD=0
item() { # item <0|1 ok> <label> [counts: 1|0]
  local ok=$1 label=$2 counts=${3:-1}
  if [ "$ok" -eq 0 ]; then
    printf '[ok] %s\n' "$label"
  else
    printf '[--] %s\n' "$label"
    [ "$counts" -eq 1 ] && CHECK_BAD=$((CHECK_BAD + 1))
  fi
  return 0
}

# file_item <label> <src> <dest>
file_item() {
  if [ -L "$3" ] || [ ! -f "$3" ]; then item 1 "$1"
  elif cmp -s "$2" "$3"; then item 0 "$1"
  else item 1 "$1 (changed)"; fi
}

# run_check_budget: budget settings, status line, model (the last is never counted).
run_check_budget() {
  local sj missing sl cur model am suffix ok
  if [ -f "$SETTINGS" ]; then sj=$(jq -c . "$SETTINGS" 2>/dev/null) || sj='{}'; else sj='{}'; fi
  missing=$(jq -r --argjson B "$(jq -c . "$BUDGET")" "$BUDGET_JQ"'report | [.[] | select(.p | not) | .n] | join(", ")' <<<"$sj")
  if [ -z "$missing" ]; then item 0 "budget settings"; else item 1 "budget settings (missing: $missing)"; fi
  sl=$(statusline_cmd)
  cur=$(jq -r 'if has("statusLine") then ((.statusLine | objects | .command) // "other") else "none" end' <<<"$sj")
  if [ "$cur" = "none" ]; then item 1 "status line"
  elif [ "$cur" = "$sl" ]; then item 0 "status line"
  else item 1 "status line (another one is set and kept, not counted)" 0; fi
  model=$(jq -r 'if has("model") then (.model | tostring) else "" end' <<<"$sj")
  am=$(jq -r '((.env | objects | .ANTHROPIC_MODEL) // empty) | tostring' <<<"$sj")
  [ -n "$am" ] || am=${ANTHROPIC_MODEL:-}
  suffix=""
  if [ -n "$am" ]; then suffix=" (ANTHROPIC_MODEL=$am overrides it)"; fi
  ok=1
  case "$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')" in *sonnet*) ok=0 ;; esac
  if [ "$ok" -eq 0 ]; then item 0 "model $model$suffix"
  else item 1 "model ${model:-not set} (the kit suggests sonnet, not counted)$suffix" 0; fi
}

run_check() {
  local with_rtk=$1 f x label ok rtk_ok
  command -v jq >/dev/null 2>&1 || die "jq is required for --check"
  CHECK_BAD=0
  for f in "$KIT"/agents/*.md; do
    file_item "agent $(basename "$f")" "$f" "$CFG/agents/$(basename "$f")"
  done
  file_item "KIT.md" "$KIT/KIT.md" "$CFG/KIT.md"
  ok=1; grep -qxF '@KIT.md' "$CFG/CLAUDE.md" 2>/dev/null && ok=0
  item "$ok" "@KIT.md line in CLAUDE.md"
  while IFS= read -r x; do
    label=$(jq -r '.event + " " + .label' <<<"$x")
    ok=1
    if [ -f "$SETTINGS" ] && jq -e --argjson x "$x" \
         '(.hooks[$x.event] // []) | any(.[]; any(.hooks[]?; .command == $x.entry.hooks[0].command))' \
         "$SETTINGS" >/dev/null 2>&1; then ok=0; fi
    item "$ok" "hook $label"
  done < <(entries_json | jq -c '.[]')
  run_check_budget
  ok=1; [ -f "$JAR" ] && ok=0
  item "$ok" "jar"
  rtk_ok=1
  if command -v rtk >/dev/null 2>&1 && [ -f "$SETTINGS" ] \
     && jq -e 'any(.hooks[]?[]?; any(.hooks[]?; (.command // "") | contains("rtk hook claude")))' "$SETTINGS" >/dev/null 2>&1; then
    rtk_ok=0
  fi
  # RTK is off by default: without --with-rtk there is no RTK line, so a clean install is all [ok].
  if [ "$with_rtk" -eq 1 ]; then item "$rtk_ok" "rtk (binary + hook)"; fi
  [ "$CHECK_BAD" -eq 0 ]
}

# ----------------------------------------------------------------- --uninstall

uninstall_budget() {
  local tmp names
  [ -f "$SETTINGS" ] || return 0
  tmp=$(mktemp)
  jq --arg kit "$KIT" --arg kitn "$(native "$KIT")" '
    if ((.statusLine | objects | .command // "") | (contains($kit) or contains($kitn)))
    then del(.statusLine) else . end
  ' "$SETTINGS" > "$tmp"
  write_if_changed "$SETTINGS" "$tmp"
  rm -f "$tmp"
  names=$(budget_present | tr '\n' ',' | sed 's/,$//; s/,/, /g')
  if [ -n "$names" ]; then say "left in settings.json (remove by hand if you want): $names"; fi
}

do_uninstall() {
  local l bak src
  command -v jq >/dev/null 2>&1 || die "jq is required for --uninstall"
  uninstall_hooks
  uninstall_budget
  if [ -f "$STATE" ]; then
    while IFS= read -r l; do
      case "$l" in file=*) l=${l#file=} ;; *) continue ;; esac
      [ -f "$l" ] || continue
      if [ "$(basename "$l")" = "KIT.md" ]; then src="$KIT/KIT.md"; else src="$KIT/agents/$(basename "$l")"; fi
      if cmp -s "$src" "$l"; then
        rm -f "$l"
        bak="$l.bak-kit"
        if [ -e "$bak" ]; then mv -f "$bak" "$l"; fi
      else
        say "kept (edited by hand): $l"
      fi
    done < "$STATE"
    rm -f "$STATE"
  fi
  if [ -f "$CFG/CLAUDE.md" ]; then
    local tmp
    tmp=$(mktemp)
    grep -vxF '@KIT.md' "$CFG/CLAUDE.md" > "$tmp" || true
    if [ -s "$tmp" ]; then cat "$tmp" > "$CFG/CLAUDE.md"; else rm -f "$CFG/CLAUDE.md"; fi
    rm -f "$tmp"
  fi
  say "claude-kit uninstalled from $CFG. $DATA and RTK were left alone."
  say "To remove RTK too: rtk init -g --uninstall"
}

# ------------------------------------------------------------------------ main

main() {
  local mode=install with_rtk=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) mode=check ;;
      --uninstall) mode=uninstall ;;
      --with-rtk) with_rtk=1 ;;
      --no-rtk) ;;
      --help|-h) usage; return 0 ;;
      *) usage >&2; return 2 ;;
    esac
    shift
  done
  if [ "$WIN" -eq 1 ] && [ "$with_rtk" -eq 1 ]; then
    say "RTK is not installed by this script on Windows (use: winget install --id rtk-ai.rtk -e, then rtk init -g)."
    with_rtk=0
  fi
  case "$mode" in
    check) if run_check "$with_rtk"; then return 0; else return 1; fi ;;
    uninstall) do_uninstall; return 0 ;;
  esac

  check_tools "$with_rtk"
  install_code_navigator
  install_files
  install_hooks
  install_budget
  if [ "$with_rtk" -eq 1 ]; then install_rtk; fi
  write_state
  say "claude-kit installed:"
  say "  code-navigator jar  $JAR"
  say "  agents and rules    $CFG/agents/*.md, $CFG/KIT.md (@KIT.md in CLAUDE.md)"
  say "  hooks               $SETTINGS (backup: settings.json.bak-kit)"
  say "  budget              added: $BUDGET_ADDED; already set, kept: $BUDGET_KEPT"
  if [ "$with_rtk" -eq 1 ]; then say "  rtk                 configured"; else say "  rtk                 skipped (use --with-rtk)"; fi
  say "Restart Claude Code."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
