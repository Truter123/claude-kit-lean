#!/usr/bin/env bash
# Refresh the code-navigator index for one project. Called from Claude Code hooks (SessionStart).
#
# Usage: cg-sync.sh [project-root]      (default: $PWD)
#
# Picks between:
#   sync  - incremental re-index (~25-45 s on a 2,000-file repo); prunes deleted/moved files too.
#   init  - full clean rebuild (~45 s), used when git shows a .java/.ts/.groovy file deleted or
#           renamed since the last indexed commit (recorded in navigators/code/.last-head).
# First run on an indexable repo auto-inits and builds the index. Every run gitignores navigators/ and wires up .mcp.json.
# Skips the home directory and any project without an index. Always exits 0.
# Jar: $CODE_NAVIGATOR_JAR, else the first existing of ${XDG_DATA_HOME:-~/.local/share}/claude-kit/
# code-navigator/jars/code-navigator.jar and ~/Documents/Tools/code-navigator/jars/code-navigator.jar.
# .mcp.json: written with jq (skipped when jq is missing); a git-tracked one is never changed; one
# this script creates is added to info/exclude. On Windows (Git Bash) jar and project paths go
# through cygpath -m, so java.exe and the MCP client get C:/ paths.

set -u
JAR="${CODE_NAVIGATOR_JAR:-}"
if [ -z "$JAR" ]; then
  for cand in "${XDG_DATA_HOME:-$HOME/.local/share}/claude-kit/code-navigator/jars/code-navigator.jar" \
              "$HOME/Documents/Tools/code-navigator/jars/code-navigator.jar"; do
    [ -f "$cand" ] && { JAR=$cand; break; }
  done
fi
[ -n "$JAR" ] && [ -f "$JAR" ] || exit 0
P="${1:-$PWD}"

[ "$P" = "$HOME" ] && exit 0
git -C "$P" rev-parse --show-toplevel >/dev/null 2>&1 || exit 0
DB="$P/navigators/code/code-navigator.db"
STAMP="$P/navigators/code/.last-head"

native_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

ensure_mcp_json() {
  local mcp_json="$P/.mcp.json"
  if grep -q '"code-navigator"' "$mcp_json" 2>/dev/null; then
    return 0
  fi
  git -C "$P" ls-files --error-unmatch .mcp.json >/dev/null 2>&1 && return 0
  command -v jq >/dev/null 2>&1 || return 0
  local created=0 base tmp
  # -b: on Windows (Git Bash) jq.exe writes CRLF otherwise.
  local jqb=(jq); case "${KIT_OS:-${OSTYPE:-}}" in msys*|cygwin*|windows) jqb=(jq -b) ;; esac
  if [ -f "$mcp_json" ]; then base=$(cat "$mcp_json"); else base='{"mcpServers":{}}'; created=1; fi
  tmp=$(mktemp "$P/.mcp.json.XXXXXX" 2>/dev/null) || return 0
  if printf '%s' "$base" | "${jqb[@]}" --arg jar "$(native_path "$JAR")" --arg p "$(native_path "$P")" \
      '.mcpServers = ((.mcpServers // {}) + {"code-navigator": {command: "java", args: ["-jar", $jar, "serve"], env: {CODE_NAVIGATOR_PROJECT: $p}}})' \
      > "$tmp" 2>/dev/null; then
    mv "$tmp" "$mcp_json"
    [ "$created" -eq 1 ] && ensure_excluded .mcp.json
  else
    rm -f "$tmp"
  fi
  return 0
}

mode=sync
head=""

ensure_excluded() {
  local exclude
  exclude="$(git -C "$P" rev-parse --path-format=absolute --git-path info/exclude)"
  mkdir -p "$(dirname "$exclude")"
  touch "$exclude"
  grep -qxF "$1" "$exclude" || echo "$1" >> "$exclude"
}

if [ ! -f "$DB" ]; then
  git -C "$P" ls-files | grep -qE '\.(java|ts|groovy|dart|py|sql|sh)$' || exit 0
  mode=init
  echo "cg-sync: first-time init $P"
else
  if git -C "$P" rev-parse --verify HEAD >/dev/null 2>&1; then
    head=$(git -C "$P" rev-parse HEAD)
    if [ -f "$STAMP" ]; then
      last=$(cat "$STAMP")
      if [ "$last" != "$head" ] && git -C "$P" cat-file -e "$last" 2>/dev/null; then
        if git -C "$P" diff --name-status --diff-filter=DR "$last" "$head" \
           | grep -qE '\.(java|ts|groovy|dart|py|sql|sh)$'; then
          mode=init
        fi
      fi
    fi
  fi
fi

# Idempotent; also repairs projects whose index predates .mcp.json wiring.
ensure_excluded 'navigators/'
ensure_mcp_json

echo "cg-sync: $mode $P"
# sqlite-jdbc unpacks its native library into the temp dir; inside the Claude sandbox /tmp is
# read-only and the sync failed silently, so point it at $TMPDIR (sandbox-writable).
if timeout 900 java -Dorg.sqlite.tmpdir="$(native_path "${TMPDIR:-/tmp}")" -jar "$(native_path "$JAR")" "$mode" "$(native_path "$P")" >/dev/null 2>&1; then
  [ -n "$head" ] && printf '%s\n' "$head" > "$STAMP"
fi
exit 0
