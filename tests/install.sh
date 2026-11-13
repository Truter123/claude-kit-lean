#!/usr/bin/env bash
# Install probes: runs install.sh --no-rtk in a throwaway HOME, twice, then --uninstall.
# The real config is never touched: HOME is replaced first and the script aborts if it is not.
#
# Usage: bash tests/install.sh
# Exit 0 = all probes passed. Needs git, jq, python3, java 21+ and a code-navigator checkout
# (CG_REPO / CG_REF, default: the clone next to this kit under ~/Documents/Tools/code-navigator).

set -u
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_HOME="$HOME"

CG_SRC="${CG_REPO:-$REAL_HOME/Documents/Tools/code-navigator}"
CG_SRC="${CG_SRC#file://}"
if [ -z "${CG_REPO:-}" ]; then
  export CG_REPO="file://$CG_SRC"
fi
if [ -z "${CG_REF:-}" ]; then
  CG_REF="$(git -C "$CG_SRC" rev-parse --abbrev-ref HEAD)"
fi
export CG_REF

THROW="$(mktemp -d)"
export HOME="$THROW"
unset CLAUDE_CONFIG_DIR XDG_DATA_HOME XDG_CONFIG_HOME
if [ -z "$THROW" ] || [ "$HOME" != "$THROW" ] || [ "$HOME" = "$REAL_HOME" ]; then
  echo "abort: HOME is not the throwaway directory" >&2
  exit 1
fi
trap 'rm -rf "$THROW"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
# is <label> <command...>: ok when the command succeeds
is() { local label=$1; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }

CFG="$HOME/.claude"
DATA="$HOME/.local/share/claude-kit"
SETTINGS="$CFG/settings.json"
INSTALL="$KIT/install.sh"
BASH_BIN="$(command -v bash)"

echo "setup (HOME=$HOME)"
mkdir -p "$CFG/agents"
cat > "$SETTINGS" <<'EOF'
{
  "model": "opus",
  "env": { "FOO": "1" },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "rtk hook claude" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "echo stopped" } ] }
    ]
  }
}
EOF
printf 'my own worker\n' > "$CFG/agents/worker.md"
printf '# my rules\n' > "$CFG/CLAUDE.md"
jq -S . "$SETTINGS" > "$THROW/before.json"

echo "install: first run"
"$BASH_BIN" "$INSTALL" --no-rtk > "$THROW/run1.out" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then ok "install --no-rtk exits 0"; else bad "install exited $RC: $(tail -3 "$THROW/run1.out")"; fi
is "jar present" test -f "$DATA/code-navigator/jars/code-navigator.jar"
cp "$SETTINGS" "$THROW/after1.json"

echo "install: second run"
"$BASH_BIN" "$INSTALL" --no-rtk > "$THROW/run2.out" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then ok "second run exits 0"; else bad "second run exited $RC: $(tail -3 "$THROW/run2.out")"; fi
if cmp -s "$THROW/after1.json" "$SETTINGS"; then ok "settings.json byte-identical after two runs"; else bad "settings.json changed on the second run"; fi

KITHOOKS=$(jq --arg k "$KIT/" --arg d "$DATA/" '[.hooks[][].hooks[] | select(.command | contains($k) or contains($d))] | length' "$SETTINGS")
KITUNIQ=$(jq --arg k "$KIT/" --arg d "$DATA/" '[.hooks | to_entries[] | .key as $e | .value[].hooks[] | select(.command | contains($k) or contains($d)) | [$e, .command]] | unique | length' "$SETTINGS")
if [ "$KITHOOKS" = 8 ] && [ "$KITUNIQ" = 8 ]; then ok "8 kit hook entries, each once"; else bad "kit hooks: $KITHOOKS entries, $KITUNIQ unique (want 8, 8; unique counts event+command)"; fi
is "unrelated keys kept" jq -e '.model == "opus" and .env.FOO == "1"' "$SETTINGS"
is "rtk hook and other Stop hook kept" jq -e '([.hooks.PreToolUse[].hooks[].command] | index("rtk hook claude")) != null and ([.hooks.Stop[].hooks[].command] | index("echo stopped")) != null' "$SETTINGS"
is "settings.json.bak-kit is the original" cmp -s "$THROW/before.json" <(jq -S . "$SETTINGS.bak-kit")

echo "install: agents, rules"
is "worker.md is now a link into the kit" test "$(readlink "$CFG/agents/worker.md")" = "$KIT/agents/worker.md"
is "original worker.md saved as worker.md.bak-kit" test "$(cat "$CFG/agents/worker.md.bak-kit" 2>/dev/null)" = "my own worker"
is "scout.md linked" test "$(readlink "$CFG/agents/scout.md")" = "$KIT/agents/scout.md"
is "KIT.md linked" test "$(readlink "$CFG/KIT.md")" = "$KIT/KIT.md"
if [ "$(grep -cxF '@KIT.md' "$CFG/CLAUDE.md")" = 1 ]; then ok "@KIT.md appears once after two runs"; else bad "@KIT.md count is not 1"; fi
is "original CLAUDE.md line kept" grep -qxF '# my rules' "$CFG/CLAUDE.md"

echo "check"
"$BASH_BIN" "$INSTALL" --check --no-rtk > "$THROW/check1.out" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then ok "--check exits 0 after install"; else bad "--check exited $RC after install: $(grep -F '[--]' "$THROW/check1.out" | head -3 | tr '\n' ';')"; fi

echo "installed hooks run"
hook_cmd() { jq -r --arg s "$1" '[.hooks[][].hooks[].command | select(contains($s))][0]' "$SETTINGS"; }
GUARD_CMD="$(hook_cmd agent-guard.sh)"
printf '%s' '{"tool_name":"Agent","tool_input":{"prompt":"x"}}' | "$BASH_BIN" -c "$GUARD_CMD" >/dev/null 2>&1
GOT=$?
if [ "$GOT" -eq 2 ]; then ok "agent-guard: a bare Agent call exits 2"; else bad "agent-guard bare call: exit $GOT"; fi
printf '%s' '{"tool_name":"Agent","tool_input":{"prompt":"x","subagent_type":"scout"}}' | "$BASH_BIN" -c "$GUARD_CMD" >/dev/null 2>&1
GOT=$?
if [ "$GOT" -eq 0 ]; then ok "agent-guard: scout exits 0"; else bad "agent-guard scout: exit $GOT"; fi

PROJ="$HOME/proj"
mkdir -p "$PROJ/src"
printf 'public class Hello {\n  public String hi() { return "hi"; }\n}\n' > "$PROJ/src/Hello.java"
git -C "$PROJ" init -q
git -C "$PROJ" add -A
git -C "$PROJ" -c user.name=t -c user.email=t@t commit -q -m init
SYNC_CMD="$(hook_cmd cg-sync.sh)"
( cd "$PROJ" && timeout 300 "$BASH_BIN" -c "$SYNC_CMD" >/dev/null 2>&1 )
is "cg-sync creates navigators/code/code-navigator.db" test -f "$PROJ/navigators/code/code-navigator.db"

echo "tool check"
mkbin() { # mkbin <dir> <tool to leave out>: symlinks of the tools install.sh needs before its tool check
  local d=$1 skip=$2 t p
  mkdir -p "$d"
  for t in git curl jq python3 java dirname sed awk tr head tail cat mkdir; do
    [ "$t" = "$skip" ] && continue
    p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$d/$t"
  done
}
sudo_lines() { grep -c '^sudo apt install -y' "$1"; }

mkbin "$THROW/bin-nojq" jq
PATH="$THROW/bin-nojq" "$BASH_BIN" "$INSTALL" --no-rtk > "$THROW/nojq.out" 2>&1
GOT=$?
if [ "$GOT" -eq 1 ] && [ "$(sudo_lines "$THROW/nojq.out")" = 1 ] && grep -q '^sudo apt install -y .*jq' "$THROW/nojq.out"; then
  ok "no jq: exit 1 and one sudo apt install line naming jq"
else bad "no jq: exit $GOT, output: $(head -3 "$THROW/nojq.out" | tr '\n' ';')"; fi

mkbin "$THROW/bin-java17" java
printf '#!/bin/sh\necho '"'"'openjdk version "17.0.9" 2023-10-17'"'"' >&2\n' > "$THROW/bin-java17/java"
chmod +x "$THROW/bin-java17/java"
PATH="$THROW/bin-java17" "$BASH_BIN" "$INSTALL" --no-rtk > "$THROW/java17.out" 2>&1
GOT=$?
if [ "$GOT" -eq 1 ] && [ "$(sudo_lines "$THROW/java17.out")" = 1 ] && grep -q '^sudo apt install -y .*openjdk-21-jre-headless' "$THROW/java17.out"; then
  ok "java 17: exit 1 and one sudo apt install line naming openjdk-21-jre-headless"
else bad "java 17: exit $GOT, output: $(head -3 "$THROW/java17.out" | tr '\n' ';')"; fi

echo "rtk config edit (rtk_set_toml)"
cat > "$THROW/sample-a.toml" <<'EOF'
[telemetry]
enabled = true
consent_given = true

[hooks]
exclude_commands = []
transparent_prefixes = []

[awareness]
level = "default"
EOF
cat > "$THROW/sample-b.toml" <<'EOF'
[telemetry]
enabled = true
consent_given = true

[hooks]
exclude_commands = []
transparent_prefixes = []
EOF
toml_ok() { # toml_ok <file> [new]: the three values and (unless "new") the untouched keys
  python3 -I - "$@" <<'PY'
import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
assert d["hooks"]["exclude_commands"] == ["git diff"], d
assert len(sys.argv) > 2 or d["hooks"]["transparent_prefixes"] == [], d
assert d["awareness"]["level"] == "full", d
assert d["telemetry"]["enabled"] is False, d
assert len(sys.argv) > 2 or d["telemetry"]["consent_given"] is True, d
PY
}
for v in a b; do
  cp "$THROW/sample-$v.toml" "$THROW/work-$v.toml"
  ( source "$INSTALL"; rtk_set_toml "$THROW/work-$v.toml" ) >/dev/null 2>&1
  is "sample $v: three values set, other keys kept" toml_ok "$THROW/work-$v.toml"
  SUM1=$(cksum < "$THROW/work-$v.toml")
  ( source "$INSTALL"; rtk_set_toml "$THROW/work-$v.toml" ) >/dev/null 2>&1
  SUM2=$(cksum < "$THROW/work-$v.toml")
  if [ "$SUM1" = "$SUM2" ]; then ok "sample $v: second call changes nothing"; else bad "sample $v: not idempotent"; fi
done
( source "$INSTALL"; rtk_set_toml "$THROW/work-new.toml" ) >/dev/null 2>&1
is "missing file: created with the three values" toml_ok "$THROW/work-new.toml" new

echo "uninstall"
"$BASH_BIN" "$INSTALL" --uninstall > "$THROW/un.out" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then ok "--uninstall exits 0"; else bad "--uninstall exited $RC: $(tail -3 "$THROW/un.out")"; fi
if cmp -s "$THROW/before.json" <(jq -S . "$SETTINGS"); then ok "jq -S . settings.json equals the original"; else bad "settings.json differs from the original"; fi
LEFT=$(find "$CFG" -type l -lname "$KIT/*" 2>/dev/null | wc -l)
if [ "$LEFT" -eq 0 ]; then ok "no link into the kit left under the config dir"; else bad "$LEFT kit links left"; fi
is "worker.md restored as a regular file" test ! -L "$CFG/agents/worker.md" -a "$(cat "$CFG/agents/worker.md" 2>/dev/null)" = "my own worker"
is "worker.md.bak-kit gone" test ! -e "$CFG/agents/worker.md.bak-kit"
is "CLAUDE.md is back to the original line" test "$(cat "$CFG/CLAUDE.md")" = "# my rules"
is "uninstall printed the rtk hint" grep -q 'rtk init -g --uninstall' "$THROW/un.out"
is "code-navigator data dir left alone" test -f "$DATA/code-navigator/jars/code-navigator.jar"
"$BASH_BIN" "$INSTALL" --check --no-rtk > "$THROW/check2.out" 2>&1
RC=$?
if [ "$RC" -eq 1 ]; then ok "--check exits 1 after uninstall"; else bad "--check exited $RC after uninstall"; fi

echo "no settings.json before the install"
EMPTY_CFG="$THROW/cfg-empty"
CLAUDE_CONFIG_DIR="$EMPTY_CFG" "$BASH_BIN" "$INSTALL" --no-rtk > "$THROW/empty1.out" 2>&1
if [ -f "$EMPTY_CFG/settings.json.bak-kit" ] && [ "$(jq -c . "$EMPTY_CFG/settings.json.bak-kit" 2>/dev/null)" = "{}" ]; then ok "first run: settings.json.bak-kit exists and is {}"; else bad "first run: bak-kit missing or not {}: $(tail -3 "$THROW/empty1.out")"; fi
CLAUDE_CONFIG_DIR="$EMPTY_CFG" "$BASH_BIN" "$INSTALL" --no-rtk > "$THROW/empty2.out" 2>&1
if [ "$(jq -c . "$EMPTY_CFG/settings.json.bak-kit" 2>/dev/null)" = "{}" ]; then ok "second run: settings.json.bak-kit still {}"; else bad "second run: bak-kit changed: $(tail -3 "$THROW/empty2.out")"; fi
CLAUDE_CONFIG_DIR="$EMPTY_CFG" "$BASH_BIN" "$INSTALL" --uninstall > "$THROW/empty3.out" 2>&1
if [ "$(jq -S -c . "$EMPTY_CFG/settings.json" 2>/dev/null)" = "{}" ]; then ok "uninstall: settings.json is {}"; else bad "uninstall: settings.json not {}: $(tail -3 "$THROW/empty3.out")"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
