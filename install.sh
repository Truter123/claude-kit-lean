#!/usr/bin/env bash
# claude-kit installer: code-navigator jar, kit agents, delegation rules, hooks, RTK.
# Safe to run twice. Never runs sudo. See --help.

set -euo pipefail

CG_REPO="${CG_REPO:-https://github.com/Truter123/code-navigator}"
CG_REF="${CG_REF:-master}"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/claude-kit"
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAR="$DATA/code-navigator/jars/code-navigator.jar"
RTK_INSTALLER_URL="https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh"
SETTINGS="$CFG/settings.json"

usage() {
  cat <<'EOF'
Usage: install.sh [--check] [--uninstall] [--no-rtk] [--help]
  --check      print one [ok] or [--] line per item; exit 0 only when all are [ok]
  --uninstall  remove kit links, the @KIT.md line and the kit hooks (RTK stays)
  --no-rtk     skip the RTK step (with --check: print the RTK item, do not count it)
  --help       this text
Environment:
  CG_REPO  code-navigator git URL (default https://github.com/Truter123/code-navigator)
  CG_REF   branch or tag to install (default master)
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

check_tools() {
  local pkgs=() jm
  command -v git >/dev/null 2>&1 || pkgs+=(git)
  if command -v git >/dev/null 2>&1 && ! git_new_enough; then pkgs+=(git); fi
  command -v curl >/dev/null 2>&1 || pkgs+=(curl)
  command -v jq >/dev/null 2>&1 || pkgs+=(jq)
  command -v python3 >/dev/null 2>&1 || pkgs+=(python3)
  jm=$(java_major)
  if [ -z "$jm" ] || ! [ "$jm" -ge 21 ] 2>/dev/null; then pkgs+=(openjdk-21-jre-headless); fi
  if [ "${#pkgs[@]}" -gt 0 ]; then
    # one line, no duplicates
    printf 'claude-kit: missing or too old (git 2.31+, curl, jq, python3, java 21+). Run:\n' >&2
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

# ------------------------------------------------------- steps 3-4: links, rules

# link_file <src> <dest>: symlink; a regular file in the way becomes <dest>.bak-kit.
link_file() {
  local src=$1 dest=$2
  mkdir -p "$(dirname "$dest")"
  if [ -L "$dest" ]; then
    [ "$(readlink "$dest")" = "$src" ] && return 0
    rm -f "$dest"
  elif [ -e "$dest" ]; then
    mv -f "$dest" "$dest.bak-kit"
  fi
  ln -s "$src" "$dest"
}

link_is_ok() { [ -L "$2" ] && [ "$(readlink "$2")" = "$1" ]; }

install_links() {
  local f
  for f in "$KIT"/agents/*.md; do
    link_file "$f" "$CFG/agents/$(basename "$f")"
  done
  link_file "$KIT/KIT.md" "$CFG/KIT.md"
  if ! grep -qxF '@KIT.md' "$CFG/CLAUDE.md" 2>/dev/null; then
    mkdir -p "$CFG"
    if [ -s "$CFG/CLAUDE.md" ] && [ -n "$(tail -c1 "$CFG/CLAUDE.md")" ]; then printf '\n' >> "$CFG/CLAUDE.md"; fi
    printf '@KIT.md\n' >> "$CFG/CLAUDE.md"
  fi
}

# ------------------------------------------------------------------ step 5: hooks

# The kit hook entries as a JSON array of {event,label,entry}. $PWD and $HOME in the
# commands are literal text for the hook's shell.
entries_json() {
  jq -nc --arg kit "$KIT" --arg jar "$JAR" '[
    {event:"PreToolUse", label:"agent-guard.sh", entry:{matcher:"Agent", hooks:[{type:"command", command:("bash " + $kit + "/hooks/agent-guard.sh"), statusMessage:"claude-kit: checking spawn"}]}},
    {event:"PreToolUse", label:"budget-guard.sh", entry:{matcher:"*", hooks:[{type:"command", command:("bash " + $kit + "/hooks/budget-guard.sh")}]}},
    (("SubagentStart","SubagentStop","SessionEnd") as $e
      | {event:$e, label:"agent-registry.sh", entry:{hooks:[{type:"command", command:("bash " + $kit + "/hooks/agent-registry.sh")}]}}),
    {event:"SessionStart", label:"cg-sync.sh", entry:{hooks:[{type:"command", command:("bash " + $kit + "/hooks/cg-sync.sh \"$PWD\""), statusMessage:"code-navigator: refreshing index", async:true}]}},
    {event:"PostToolUse", label:"mark-dirty", entry:{matcher:"Edit|Write|MultiEdit|NotebookEdit", hooks:[{type:"command", command:("[ \"$PWD\" != \"$HOME\" ] && [ -f \"$PWD/navigators/code/code-navigator.db\" ] && java -jar " + $jar + " mark-dirty \"$PWD\"; true"), statusMessage:"code-navigator: marking index dirty", async:true}]}},
    {event:"Stop", label:"sync-if-dirty", entry:{matcher:"", hooks:[{type:"command", command:("[ \"$PWD\" != \"$HOME\" ] && [ -f \"$PWD/navigators/code/.dirty\" ] && timeout 600 java -jar " + $jar + " sync-if-dirty \"$PWD\"; true"), statusMessage:"code-navigator: syncing index", async:true}]}}
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
  jq --arg kit "$KIT/" --arg data "$DATA/" '
    if (.hooks | type) == "object" then
      .hooks |= (
        with_entries(
          .value |= (
            map(.hooks = ((.hooks // []) | map(select(((.command // "") | (contains($kit) or contains($data))) | not))))
            | map(select((.hooks | length) > 0))))
        | with_entries(select((.value | length) > 0)))
      | if .hooks == {} then del(.hooks) else . end
    else . end
  ' "$SETTINGS" > "$tmp"
  write_if_changed "$SETTINGS" "$tmp"
  rm -f "$tmp"
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

run_check() {
  local with_rtk=$1 f x label ok rtk_ok
  command -v jq >/dev/null 2>&1 || die "jq is required for --check"
  CHECK_BAD=0
  for f in "$KIT"/agents/*.md; do
    ok=1; link_is_ok "$f" "$CFG/agents/$(basename "$f")" && ok=0
    item "$ok" "agent $(basename "$f")"
  done
  ok=1; link_is_ok "$KIT/KIT.md" "$CFG/KIT.md" && ok=0
  item "$ok" "KIT.md link"
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
  ok=1; [ -f "$JAR" ] && ok=0
  item "$ok" "jar"
  rtk_ok=1
  if command -v rtk >/dev/null 2>&1 && [ -f "$SETTINGS" ] \
     && jq -e 'any(.hooks[]?[]?; any(.hooks[]?; (.command // "") | contains("rtk hook claude")))' "$SETTINGS" >/dev/null 2>&1; then
    rtk_ok=0
  fi
  if [ "$with_rtk" -eq 1 ]; then item "$rtk_ok" "rtk (binary + hook)"; else item "$rtk_ok" "rtk (binary + hook, not counted)" 0; fi
  [ "$CHECK_BAD" -eq 0 ]
}

# ----------------------------------------------------------------- --uninstall

do_uninstall() {
  local l bak
  command -v jq >/dev/null 2>&1 || die "jq is required for --uninstall"
  uninstall_hooks
  for l in "$CFG"/agents/* "$CFG/KIT.md"; do
    [ -L "$l" ] || continue
    case "$(readlink "$l")" in "$KIT"/*) ;; *) continue ;; esac
    rm -f "$l"
    bak="$l.bak-kit"
    if [ -e "$bak" ]; then mv -f "$bak" "$l"; fi
  done
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
  local mode=install with_rtk=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) mode=check ;;
      --uninstall) mode=uninstall ;;
      --no-rtk) with_rtk=0 ;;
      --help|-h) usage; return 0 ;;
      *) usage >&2; return 2 ;;
    esac
    shift
  done
  case "$mode" in
    check) if run_check "$with_rtk"; then return 0; else return 1; fi ;;
    uninstall) do_uninstall; return 0 ;;
  esac

  check_tools
  install_code_navigator
  install_links
  install_hooks
  [ "$with_rtk" -eq 1 ] && install_rtk
  say "claude-kit installed:"
  say "  code-navigator jar  $JAR"
  say "  agents and rules    $CFG/agents/*.md, $CFG/KIT.md (@KIT.md in CLAUDE.md)"
  say "  hooks               $SETTINGS (backup: settings.json.bak-kit)"
  if [ "$with_rtk" -eq 1 ]; then say "  rtk                 configured"; else say "  rtk                 skipped (--no-rtk)"; fi
  say "Restart Claude Code."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
