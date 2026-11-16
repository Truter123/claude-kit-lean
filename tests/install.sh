#!/usr/bin/env bash
# Install probes: runs install.sh in a throwaway HOME, twice, then --uninstall; also CG_REF memory, state file, RTK opt-in.
# The real config is never touched: HOME is replaced first and the script aborts if it is not.
#
# Usage: bash tests/install.sh
# Exit 0 = all probes passed. Needs git, jq, python3 (rtk_set_toml probes), java 21+ and a code-navigator checkout
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
unset CLAUDE_CONFIG_DIR XDG_DATA_HOME XDG_CONFIG_HOME APPDATA USERPROFILE KIT_OS
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
# expected <settings.json>: that file plus the budget keys the install adds (add if missing), without statusLine, jq -S
expected() { jq -S --slurpfile b "$KIT/settings/budget.json" '$b[0] as $B | . as $o | ($B + $o) | .env = ($B.env + ($o.env // {}))' "$1"; }

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
printf 'my own scout\n' > "$CFG/agents/scout.md"
printf '# my rules\n' > "$CFG/CLAUDE.md"
jq -S . "$SETTINGS" > "$THROW/before.json"

echo "install: first run"
"$BASH_BIN" "$INSTALL" > "$THROW/run1.out" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then ok "install exits 0"; else bad "install exited $RC: $(tail -3 "$THROW/run1.out")"; fi
is "jar present" test -f "$DATA/code-navigator/jars/code-navigator.jar"
cp "$SETTINGS" "$THROW/after1.json"
snapshot() { ( cd "$CFG" && find . -type f -not -name '*.bak-kit' | sort | xargs cksum ); }
snapshot > "$THROW/snap1.txt"
is "run printed rtk skipped" grep -q 'rtk  *skipped (use --with-rtk)' "$THROW/run1.out"

echo "install: second run"
"$BASH_BIN" "$INSTALL" > "$THROW/run2.out" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then ok "second run exits 0"; else bad "second run exited $RC: $(tail -3 "$THROW/run2.out")"; fi
snapshot > "$THROW/snap2.txt"
if cmp -s "$THROW/snap1.txt" "$THROW/snap2.txt"; then ok "settings, state file and installed files byte-identical after two runs"; else bad "files changed on the second run"; fi
is "state file has one cg_ref line and file lines" test "$(grep -c '^cg_ref=' "$CFG/.claude-kit-state")" = 1 -a "$(grep -c '^file=' "$CFG/.claude-kit-state")" -ge 4
is "state file lists KIT.md" grep -qxF "file=$CFG/KIT.md" "$CFG/.claude-kit-state"
if cmp -s "$THROW/after1.json" "$SETTINGS"; then ok "settings.json byte-identical after two runs"; else bad "settings.json changed on the second run"; fi

KITHOOKS=$(jq --arg k "$KIT/" --arg d "$DATA/" '[.hooks[][].hooks[] | select(.command | contains($k) or contains($d))] | length' "$SETTINGS")
KITUNIQ=$(jq --arg k "$KIT/" --arg d "$DATA/" '[.hooks | to_entries[] | .key as $e | .value[].hooks[] | select(.command | contains($k) or contains($d)) | [$e, .command]] | unique | length' "$SETTINGS")
if [ "$KITHOOKS" = 8 ] && [ "$KITUNIQ" = 8 ]; then ok "8 kit hook entries, each once"; else bad "kit hooks: $KITHOOKS entries, $KITUNIQ unique (want 8, 8; unique counts event+command)"; fi
is "unrelated keys kept" jq -e '.model == "opus" and .env.FOO == "1"' "$SETTINGS"
is "rtk hook and other Stop hook kept" jq -e '([.hooks.PreToolUse[].hooks[].command] | index("rtk hook claude")) != null and ([.hooks.Stop[].hooks[].command] | index("echo stopped")) != null' "$SETTINGS"
is "settings.json.bak-kit is the original" cmp -s "$THROW/before.json" <(jq -S . "$SETTINGS.bak-kit")

echo "install: agents, rules"
same_file() { [ ! -L "$2" ] && [ -f "$2" ] && cmp -s "$1" "$2"; }
for n in worker scout engineer; do
  is "$n.md is a regular file equal to the kit source" same_file "$KIT/agents/$n.md" "$CFG/agents/$n.md"
done
is "KIT.md is a regular file equal to the kit source" same_file "$KIT/KIT.md" "$CFG/KIT.md"
is "original worker.md saved as worker.md.bak-kit" test "$(cat "$CFG/agents/worker.md.bak-kit" 2>/dev/null)" = "my own worker"
is "foreign scout.md saved as scout.md.bak-kit" test "$(cat "$CFG/agents/scout.md.bak-kit" 2>/dev/null)" = "my own scout"
if [ "$(grep -cxF '@KIT.md' "$CFG/CLAUDE.md")" = 1 ]; then ok "@KIT.md appears once after two runs"; else bad "@KIT.md count is not 1"; fi
is "original CLAUDE.md line kept" grep -qxF '# my rules' "$CFG/CLAUDE.md"

echo "check"
"$BASH_BIN" "$INSTALL" --check > "$THROW/check1.out" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then ok "--check exits 0 after install"; else bad "--check exited $RC after install: $(grep -F '[--]' "$THROW/check1.out" | head -3 | tr '\n' ';')"; fi
is "--check prints [ok] agent scout.md" grep -qxF '[ok] agent scout.md' "$THROW/check1.out"
if grep -qi 'rtk' "$THROW/check1.out"; then bad "--check without --with-rtk printed an rtk line"; else ok "--check without --with-rtk prints no rtk line"; fi
# This config has a pre-set model: "opus", so the one [--] line allowed here is the model hint.
if [ "$(grep -c '^\[--\]' "$THROW/check1.out")" = 1 ] && grep -qF '[--] model opus (the kit suggests sonnet, not counted)' "$THROW/check1.out"; then ok "--check: the only [--] line is the not-counted model hint"; else bad "--check has other [--] lines: $(grep '^\[--\]' "$THROW/check1.out" | head -3 | tr '\n' ';')"; fi

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
mkbin() { # mkbin <dir> <tools to leave out, space separated>: symlinks of the tools install.sh needs before its tool check
  local d=$1 skip=$2 t p
  mkdir -p "$d"
  for t in git curl jq python3 java dirname basename sed awk tr head tail cat mkdir cp cmp mv rm mktemp grep sh env; do
    case " $skip " in *" $t "*) continue ;; esac
    p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$d/$t"
  done
}
sudo_lines() { grep -c '^sudo apt install -y' "$1"; }

mkbin "$THROW/bin-nojq" jq
PATH="$THROW/bin-nojq" "$BASH_BIN" "$INSTALL" > "$THROW/nojq.out" 2>&1
GOT=$?
if [ "$GOT" -eq 1 ] && [ "$(sudo_lines "$THROW/nojq.out")" = 1 ] && grep -q '^sudo apt install -y .*jq' "$THROW/nojq.out"; then
  ok "no jq: exit 1 and one sudo apt install line naming jq"
else bad "no jq: exit $GOT, output: $(head -3 "$THROW/nojq.out" | tr '\n' ';')"; fi

mkbin "$THROW/bin-java17" java
printf '#!/bin/sh\necho '"'"'openjdk version "17.0.9" 2023-10-17'"'"' >&2\n' > "$THROW/bin-java17/java"
chmod +x "$THROW/bin-java17/java"
PATH="$THROW/bin-java17" "$BASH_BIN" "$INSTALL" > "$THROW/java17.out" 2>&1
GOT=$?
if [ "$GOT" -eq 1 ] && [ "$(sudo_lines "$THROW/java17.out")" = 1 ] && grep -q '^sudo apt install -y .*openjdk-21-jre-headless' "$THROW/java17.out"; then
  ok "java 17: exit 1 and one sudo apt install line naming openjdk-21-jre-headless"
else bad "java 17: exit $GOT, output: $(head -3 "$THROW/java17.out" | tr '\n' ';')"; fi

mkbin "$THROW/bin-nocurl" "curl python3"
CLAUDE_CONFIG_DIR="$THROW/cfg-nocurl" XDG_DATA_HOME="$THROW/data-nocurl" PATH="$THROW/bin-nocurl" "$BASH_BIN" "$INSTALL" > "$THROW/nocurl.out" 2>&1
GOT=$?
if [ "$GOT" -eq 0 ]; then ok "no curl, no python3: default install succeeds"; else bad "no curl/python3: exit $GOT, output: $(tail -3 "$THROW/nocurl.out" | tr '\n' ';')"; fi
CLAUDE_CONFIG_DIR="$THROW/cfg-nocurl" XDG_DATA_HOME="$THROW/data-nocurl" PATH="$THROW/bin-nocurl" "$BASH_BIN" "$INSTALL" --with-rtk > "$THROW/nocurl2.out" 2>&1
GOT=$?
if [ "$GOT" -eq 1 ] && grep -q '^sudo apt install -y .*curl' "$THROW/nocurl2.out"; then ok "--with-rtk without curl: exit 1 naming curl"; else bad "--with-rtk without curl: exit $GOT"; fi

echo "no rtk by default, --no-rtk accepted, hand-edited file"
ECFG="$THROW/cfg-edit"
CLAUDE_CONFIG_DIR="$ECFG" "$BASH_BIN" "$INSTALL" --no-rtk > "$THROW/edit1.out" 2>&1
GOT=$?
if [ "$GOT" -eq 0 ]; then ok "--no-rtk still exits 0"; else bad "--no-rtk exited $GOT: $(tail -3 "$THROW/edit1.out")"; fi
is "default install added no rtk hook" jq -e '[.. | strings | select(contains("rtk hook claude"))] | length == 0' "$ECFG/settings.json"
printf 'edited\n' >> "$ECFG/KIT.md"
CLAUDE_CONFIG_DIR="$ECFG" "$BASH_BIN" "$INSTALL" --check > "$THROW/edit2.out" 2>&1
GOT=$?
if [ "$GOT" -eq 1 ] && grep -qxF '[--] KIT.md (changed)' "$THROW/edit2.out"; then ok "edited KIT.md: --check exits 1 with (changed)"; else bad "edited KIT.md: --check exit $GOT: $(grep -F '[--]' "$THROW/edit2.out" | tr '\n' ';')"; fi
CLAUDE_CONFIG_DIR="$ECFG" "$BASH_BIN" "$INSTALL" --uninstall > "$THROW/edit3.out" 2>&1
is "edited KIT.md survives --uninstall" grep -qxF 'edited' "$ECFG/KIT.md"
is "--uninstall prints the edited path" grep -qxF "kept (edited by hand): $ECFG/KIT.md" "$THROW/edit3.out"
is "state file gone after that --uninstall" test ! -e "$ECFG/.claude-kit-state"

echo "CG_REF memory"
CGC="$THROW/cgclone"
git clone -q --no-hardlinks "$CG_SRC" "$CGC" >/dev/null 2>&1
git -C "$CGC" checkout -q -b alt-ref
git -C "$CGC" -c user.name=t -c user.email=t@t commit -q --allow-empty -m alt
ALT_TIP="$(git -C "$CGC" rev-parse alt-ref)"
RCFG="$THROW/cfg-ref"; RDATA="$THROW/data-ref"
CLAUDE_CONFIG_DIR="$RCFG" XDG_DATA_HOME="$RDATA" CG_REPO="file://$CGC" CG_REF=alt-ref "$BASH_BIN" "$INSTALL" > "$THROW/ref1.out" 2>&1
is "CG_REF=alt-ref: data clone on the branch tip" test "$(git -C "$RDATA/claude-kit/code-navigator" rev-parse HEAD)" = "$ALT_TIP"
env -u CG_REF CLAUDE_CONFIG_DIR="$RCFG" XDG_DATA_HOME="$RDATA" CG_REPO="file://$CGC" "$BASH_BIN" "$INSTALL" > "$THROW/ref2.out" 2>&1
GOT=$?
if [ "$GOT" -eq 0 ]; then ok "run without CG_REF exits 0"; else bad "run without CG_REF exited $GOT: $(tail -3 "$THROW/ref2.out")"; fi
is "no CG_REF: data clone still on the branch tip" test "$(git -C "$RDATA/claude-kit/code-navigator" rev-parse HEAD)" = "$ALT_TIP"
is "state file says cg_ref=alt-ref" grep -qxF 'cg_ref=alt-ref' "$RCFG/.claude-kit-state"

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

echo "budget profile"
BJ="$KIT/settings/budget.json"
BDATA="$THROW/data-budget"
brun() { local c=$1; shift; CLAUDE_CONFIG_DIR="$c" XDG_DATA_HOME="$BDATA" "$BASH_BIN" "$INSTALL" "$@"; }
seed() { mkdir -p "$1"; printf '%s\n' "$2" > "$1/settings.json"; }

B1="$THROW/cfg-b1"
seed "$B1" '{}'
brun "$B1" > "$THROW/b1a.out" 2>&1
GOT=$?
if [ "$GOT" -eq 0 ]; then ok "budget: install into {} exits 0"; else bad "budget: install exited $GOT: $(tail -3 "$THROW/b1a.out")"; fi
is "budget: every budget.json key added with the file's value" jq -e --slurpfile b "$BJ" '. as $s | $b[0] as $B
  | all(($B | del(.env, .permissions) | to_entries[]); . as $e | $s[$e.key] == $e.value)
    and all(($B.env | to_entries[]); . as $e | $s.env[$e.key] == $e.value)
    and ($B.permissions.deny | length) == 2 and all($B.permissions.deny[]; . as $d | $s.permissions.deny | index([$d]) != null)' "$B1/settings.json"
is "budget: statusLine command points at bin/statusline.sh in the kit" jq -e --arg k "$KIT/bin/statusline.sh" '.statusLine.type == "command" and (.statusLine.command | contains($k))' "$B1/settings.json"
is "budget: first run summary has the budget line naming model" grep -qE '^  budget +added: .*model.*; already set, kept: nothing$' "$THROW/b1a.out"
cp "$B1/settings.json" "$THROW/b1-after1.json"
brun "$B1" > "$THROW/b1b.out" 2>&1
if cmp -s "$THROW/b1-after1.json" "$B1/settings.json"; then ok "budget: second run leaves settings.json byte-identical"; else bad "budget: settings.json changed on the second run"; fi
is "budget: second run says added: nothing" grep -qE '^  budget +added: nothing; ' "$THROW/b1b.out"
brun "$B1" --check > "$THROW/b1c.out" 2>&1
GOT=$?
if [ "$GOT" -eq 0 ]; then ok "budget: --check exits 0 on a fresh install"; else bad "budget: --check exited $GOT: $(grep -F '[--]' "$THROW/b1c.out" | tr '\n' ';')"; fi
is "budget: --check [ok] budget settings" grep -qxF '[ok] budget settings' "$THROW/b1c.out"
is "budget: --check [ok] status line" grep -qxF '[ok] status line' "$THROW/b1c.out"
is "budget: --check [ok] model sonnet" grep -qxF '[ok] model sonnet' "$THROW/b1c.out"
SL_CMD="$(jq -r '.statusLine.command' "$B1/settings.json")"
SL_OUT="$(printf '%s' '{"model":{"display_name":"Sonnet"},"cost":{"total_cost_usd":1.5},"session_id":"t"}' | XDG_DATA_HOME="$BDATA" NO_COLOR=1 "$BASH_BIN" -c "$SL_CMD" 2>&1)"
if printf '%s' "$SL_OUT" | grep -qF 'month $'; then ok "budget: the installed status line runs and prints month \$"; else bad "budget: status line output: $SL_OUT"; fi

# a key deleted by hand
jq 'del(.autoCompactWindow)' "$B1/settings.json" > "$THROW/b1-del.json" && cp "$THROW/b1-del.json" "$B1/settings.json"
brun "$B1" --check > "$THROW/b1d.out" 2>&1
GOT=$?
if [ "$GOT" -eq 1 ] && grep -qxF '[--] budget settings (missing: autoCompactWindow)' "$THROW/b1d.out"; then ok "budget: --check after deleting a key exits 1 and names it"; else bad "budget: --check exit $GOT: $(grep -F 'budget' "$THROW/b1d.out")"; fi

# uninstall
brun "$B1" --uninstall > "$THROW/b1e.out" 2>&1
is "budget: --uninstall removed the kit status line" jq -e 'has("statusLine") | not' "$B1/settings.json"
is "budget: --uninstall left the budget keys" jq -e '.model == "sonnet" and .env.KIT_BUDGET_USD == "250" and (.permissions.deny | length) == 2' "$B1/settings.json"
is "budget: --uninstall prints the left-in-settings line naming them" grep -qE '^left in settings.json \(remove by hand if you want\): .*model.*env\.KIT_BUDGET_USD.*permissions\.deny' "$THROW/b1e.out"

# pre-set values survive
B2="$THROW/cfg-b2"
seed "$B2" '{"model":"opus","promptSuggestionEnabled":true,"awaySummaryEnabled":null,"env":{"ANTHROPIC_MODEL":"x","BASH_MAX_OUTPUT_LENGTH":"5000"}}'
brun "$B2" > "$THROW/b2a.out" 2>&1
is "budget: pre-set model, ANTHROPIC_MODEL, BASH_MAX_OUTPUT_LENGTH survive" jq -e '.model == "opus" and .env.ANTHROPIC_MODEL == "x" and .env.BASH_MAX_OUTPUT_LENGTH == "5000"' "$B2/settings.json"
is "budget: pre-set true and null stay" jq -e '.promptSuggestionEnabled == true and has("awaySummaryEnabled") and .awaySummaryEnabled == null' "$B2/settings.json"
is "budget: the other budget keys are added" jq -e --slurpfile b "$BJ" '.effortLevel == $b[0].effortLevel and .promptCacheTtl == $b[0].promptCacheTtl and .autoCompactWindow == $b[0].autoCompactWindow and .env.KIT_BUDGET_USD == $b[0].env.KIT_BUDGET_USD' "$B2/settings.json"
is "budget: summary lists the kept keys" grep -qE 'already set, kept: .*model' "$THROW/b2a.out"
brun "$B2" --check > "$THROW/b2c.out" 2>&1
GOT=$?
if [ "$GOT" -eq 0 ] && grep -qxF '[--] model opus (the kit suggests sonnet, not counted) (ANTHROPIC_MODEL=x overrides it)' "$THROW/b2c.out"; then ok "budget: --check with model opus and ANTHROPIC_MODEL: not counted, names the override"; else bad "budget: --check exit $GOT: $(grep -F 'model' "$THROW/b2c.out")"; fi
B2B="$THROW/cfg-b2b"
seed "$B2B" '{"model":"opus"}'
brun "$B2B" > /dev/null 2>&1
brun "$B2B" --check > "$THROW/b2d.out" 2>&1
GOT=$?
if [ "$GOT" -eq 0 ] && grep -qxF '[--] model opus (the kit suggests sonnet, not counted)' "$THROW/b2d.out"; then ok "budget: --check with model opus: exit 0 and the suggestion line"; else bad "budget: --check exit $GOT: $(grep -F 'model' "$THROW/b2d.out")"; fi

# deny union
B3="$THROW/cfg-b3"
seed "$B3" '{"permissions":{"deny":["Bash(rm -rf *)","Read(./.env)"],"allow":["Bash(ls)"]}}'
brun "$B3" > /dev/null 2>&1
is "budget: deny union keeps order, no duplicate, allow unchanged" jq -e '.permissions.deny == ["Bash(rm -rf *)","Read(./.env)","Read(./.env.*)"] and .permissions.allow == ["Bash(ls)"]' "$B3/settings.json"

# a foreign status line
B4="$THROW/cfg-b4"
seed "$B4" '{"statusLine":{"type":"command","command":"echo mine"}}'
brun "$B4" > /dev/null 2>&1
is "budget: a pre-existing statusLine is kept" jq -e '.statusLine.command == "echo mine"' "$B4/settings.json"
brun "$B4" --check > "$THROW/b4c.out" 2>&1
GOT=$?
if [ "$GOT" -eq 0 ] && grep -qxF '[--] status line (another one is set and kept, not counted)' "$THROW/b4c.out"; then ok "budget: --check says another status line is kept and exits 0"; else bad "budget: --check exit $GOT: $(grep -F 'status' "$THROW/b4c.out")"; fi
brun "$B4" --uninstall > /dev/null 2>&1
is "budget: --uninstall does not remove a foreign status line" jq -e '.statusLine.command == "echo mine"' "$B4/settings.json"

echo "uninstall"
"$BASH_BIN" "$INSTALL" --uninstall > "$THROW/un.out" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then ok "--uninstall exits 0"; else bad "--uninstall exited $RC: $(tail -3 "$THROW/un.out")"; fi
expected "$THROW/before.json" > "$THROW/before-expected.json"
if cmp -s "$THROW/before-expected.json" <(jq -S . "$SETTINGS"); then ok "jq -S . settings.json equals the original plus the budget keys the install added, no status line"; else bad "settings.json differs from the original plus budget keys"; fi
is "state file gone after --uninstall" test ! -e "$CFG/.claude-kit-state"
is "no kit agent or KIT.md left" test ! -e "$CFG/KIT.md" -a ! -e "$CFG/agents/engineer.md"
is "scout.md restored with its old content" test "$(cat "$CFG/agents/scout.md" 2>/dev/null)" = "my own scout"
is "scout.md.bak-kit gone" test ! -e "$CFG/agents/scout.md.bak-kit"
is "worker.md restored as a regular file" test ! -L "$CFG/agents/worker.md" -a "$(cat "$CFG/agents/worker.md" 2>/dev/null)" = "my own worker"
is "worker.md.bak-kit gone" test ! -e "$CFG/agents/worker.md.bak-kit"
is "CLAUDE.md is back to the original line" test "$(cat "$CFG/CLAUDE.md")" = "# my rules"
is "uninstall printed the rtk hint" grep -q 'rtk init -g --uninstall' "$THROW/un.out"
is "code-navigator data dir left alone" test -f "$DATA/code-navigator/jars/code-navigator.jar"
"$BASH_BIN" "$INSTALL" --check > "$THROW/check2.out" 2>&1
RC=$?
if [ "$RC" -eq 1 ]; then ok "--check exits 1 after uninstall"; else bad "--check exited $RC after uninstall"; fi

echo "no settings.json before the install"
EMPTY_CFG="$THROW/cfg-empty"
CLAUDE_CONFIG_DIR="$EMPTY_CFG" "$BASH_BIN" "$INSTALL" > "$THROW/empty1.out" 2>&1
if [ -f "$EMPTY_CFG/settings.json.bak-kit" ] && [ "$(jq -c . "$EMPTY_CFG/settings.json.bak-kit" 2>/dev/null)" = "{}" ]; then ok "first run: settings.json.bak-kit exists and is {}"; else bad "first run: bak-kit missing or not {}: $(tail -3 "$THROW/empty1.out")"; fi
CLAUDE_CONFIG_DIR="$EMPTY_CFG" "$BASH_BIN" "$INSTALL" > "$THROW/empty2.out" 2>&1
if [ "$(jq -c . "$EMPTY_CFG/settings.json.bak-kit" 2>/dev/null)" = "{}" ]; then ok "second run: settings.json.bak-kit still {}"; else bad "second run: bak-kit changed: $(tail -3 "$THROW/empty2.out")"; fi
CLAUDE_CONFIG_DIR="$EMPTY_CFG" "$BASH_BIN" "$INSTALL" --uninstall > "$THROW/empty3.out" 2>&1
if [ "$(jq -S -c . "$EMPTY_CFG/settings.json" 2>/dev/null)" = "$(jq -S -c . "$KIT/settings/budget.json")" ]; then ok "uninstall: settings.json is the budget keys only"; else bad "uninstall: settings.json not the budget keys: $(tail -3 "$THROW/empty3.out")"; fi

echo "kit path with a space"
SPK="$THROW/my kit/claude-kit"
mkdir -p "$SPK"
tar --exclude=.git -C "$KIT" -cf - . | tar -C "$SPK" -xf -
SPCFG="$THROW/cfg-space"
CLAUDE_CONFIG_DIR="$SPCFG" XDG_DATA_HOME="$THROW/data-space" "$BASH_BIN" "$SPK/install.sh" > "$THROW/space1.out" 2>&1
GOT=$?
if [ "$GOT" -eq 0 ]; then ok "install from a kit path with a space exits 0"; else bad "space install exited $GOT: $(tail -3 "$THROW/space1.out")"; fi
CLAUDE_CONFIG_DIR="$SPCFG" XDG_DATA_HOME="$THROW/data-space" "$BASH_BIN" "$SPK/install.sh" --check > "$THROW/space2.out" 2>&1
GOT=$?
if [ "$GOT" -eq 0 ]; then ok "space path: --check exits 0"; else bad "space path --check exited $GOT"; fi
SP_CMD="$(jq -r '[.hooks[][].hooks[].command | select(contains("agent-guard.sh"))][0]' "$SPCFG/settings.json")"
printf '{}' | "$BASH_BIN" -c "$SP_CMD" >/dev/null 2>&1
GOT=$?
if [ "$GOT" -eq 2 ]; then ok "space path: installed agent-guard command runs and the guard exits 2"; else bad "space path agent-guard: exit $GOT (cmd: $SP_CMD)"; fi

echo "windows mode (simulated)"
WH="$THROW/winhome"
WCFG="$WH/.claude"
WDATA="$WH/.local/share/claude-kit"
WSET="$WCFG/settings.json"
REAL_JQ="$(command -v jq)"
mkwin() { # mkwin <dir>: put the fake cygpath and the fake (CRLF-writing) jq into <dir>
  local d=$1
  mkdir -p "$d"
  cat > "$d/cygpath" <<'EOF'
#!/bin/sh
case "$1" in
  -m) printf 'C:%s\n' "$2" ;;
  -u) printf '%s\n' "${2#C:}" ;;
  *) exit 1 ;;
esac
EOF
  cat > "$d/jq" <<EOF
#!$BASH_BIN
for a in "\$@"; do
  if [ "\$a" = "-b" ]; then exec "$REAL_JQ" "\$@"; fi
done
"$REAL_JQ" "\$@" | while IFS= read -r line; do printf '%s\r\n' "\$line"; done
exit \${PIPESTATUS[0]}
EOF
  chmod +x "$d/cygpath" "$d/jq"
}
mkwin "$THROW/winfake"
is "fake jq appends CR without -b" test "$(echo '{}' | PATH="$THROW/winfake:$PATH" jq . | od -An -c | tr -d ' ')" = '{}\r\n'
mkdir -p "$WCFG"
printf '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo stopped"}]}]}}\n' > "$WSET"
jq -S . "$WSET" > "$THROW/win-before.json"
winrun() { HOME="$WH" KIT_OS=windows PATH="$THROW/winfake:$PATH" "$BASH_BIN" "$INSTALL" "$@"; }

winrun > "$THROW/win1.out" 2>&1
GOT=$?
if [ "$GOT" -eq 0 ]; then ok "windows: install exits 0"; else bad "windows install exited $GOT: $(tail -3 "$THROW/win1.out")"; fi
winrun --check > "$THROW/win-check.out" 2>&1
GOT=$?
if [ "$GOT" -eq 0 ]; then ok "windows: --check exits 0"; else bad "windows --check exited $GOT: $(grep -F '[--]' "$THROW/win-check.out" | head -3 | tr '\n' ';')"; fi
WJAR="$WDATA/code-navigator/jars/code-navigator.jar"
if jq -e --arg k "$KIT" --arg j "$WJAR" '
     [.hooks[][].hooks[].command | select(contains($k) or contains($j))] as $c
     | ($c | length) == 8
       and all($c[]; . as $x
         | all([$k, $j][]; . as $p | ($x | split($p) | .[:-1] | all(.[]; endswith("C:")))))' "$WSET" >/dev/null 2>&1; then
  ok "windows: 8 kit hook commands, every kit and jar path occurrence preceded by C:"
else bad "windows: hook command paths not all converted: $(jq -c '[.hooks[][].hooks[].command]' "$WSET")"; fi
is "windows: mark-dirty and sync-if-dirty use pwd -W" jq -e '
  ([.hooks[][].hooks[].command | select(contains("mark-dirty") or contains("sync-if-dirty"))] | length) == 2
  and all(.hooks[][].hooks[].command | select(contains("mark-dirty") or contains("sync-if-dirty")); contains("pwd -W"))' "$WSET"
is "windows: cg-sync.sh command keeps \"\$PWD\"" jq -e '[.hooks[][].hooks[].command | select(contains("cg-sync.sh"))] | length == 1 and all(.[]; contains("\"$PWD\""))' "$WSET"
if ! grep -q $'\r' "$WSET" && ! grep -q $'\r' "$WCFG/.claude-kit-state"; then ok "windows: no CR in settings.json or the state file"; else bad "windows: CR found in settings.json or the state file"; fi
cp "$WSET" "$THROW/win-after1.json"
winrun > "$THROW/win2.out" 2>&1
if cmp -s "$THROW/win-after1.json" "$WSET"; then ok "windows: second run leaves settings.json byte-identical"; else bad "windows: settings.json changed on the second run"; fi

is "windows: statusLine command holds the kit path only in converted form" jq -e --arg k "$KIT" '.statusLine.command | contains("C:" + $k + "/bin/statusline.sh") and (split($k) | .[:-1] | all(.[]; endswith("C:")))' "$WSET"
if ! grep -q $'\r' "$WSET"; then ok "windows: settings.json holds no CR after the budget step"; else bad "windows: CR in settings.json"; fi
winrun --check > "$THROW/win-check2.out" 2>&1
GOT=$?
if [ "$GOT" -eq 0 ] && grep -qxF '[ok] status line' "$THROW/win-check2.out"; then ok "windows: --check exits 0 with the status line ok"; else bad "windows: --check exit $GOT: $(grep -F '[--]' "$THROW/win-check2.out" | tr '\n' ';')"; fi

mkbin "$THROW/bin-win-nojava" "jq java"
mkwin "$THROW/bin-win-nojava"
HOME="$WH" KIT_OS=windows PATH="$THROW/bin-win-nojava" "$BASH_BIN" "$INSTALL" > "$THROW/win-nojava.out" 2>&1
GOT=$?
if [ "$GOT" -eq 1 ] && grep -qF 'winget install --id EclipseAdoptium.Temurin.21.JRE -e' "$THROW/win-nojava.out" && ! grep -q 'apt' "$THROW/win-nojava.out"; then
  ok "windows, no java: exit 1, winget line, no apt"
else bad "windows, no java: exit $GOT, output: $(head -3 "$THROW/win-nojava.out" | tr '\n' ';')"; fi

mkbin "$THROW/bin-win-nocurl" "jq curl python3"
mkwin "$THROW/bin-win-nocurl"
HOME="$WH" KIT_OS=windows PATH="$THROW/bin-win-nocurl" "$BASH_BIN" "$INSTALL" > "$THROW/win-nocurl.out" 2>&1
GOT=$?
if [ "$GOT" -eq 0 ]; then ok "windows, no curl or python3: install exits 0"; else bad "windows, no curl/python3: exit $GOT: $(tail -3 "$THROW/win-nocurl.out" | tr '\n' ';')"; fi

winrun --with-rtk > "$THROW/win-rtk.out" 2>&1
GOT=$?
if [ "$GOT" -eq 0 ] && grep -qF 'RTK is not installed by this script on Windows' "$THROW/win-rtk.out"; then ok "windows --with-rtk: exit 0 and the RTK line"; else bad "windows --with-rtk: exit $GOT"; fi
is "windows --with-rtk added no rtk hook" jq -e '[.. | strings | select(contains("rtk hook claude"))] | length == 0' "$WSET"

mkbin "$THROW/bin-uname" java
printf '#!/bin/sh\n[ "$1" = "-s" ] && echo MINGW64_NT-10.0-19045 || echo x\n' > "$THROW/bin-uname/uname"
chmod +x "$THROW/bin-uname/uname"
HOME="$WH" PATH="$THROW/bin-uname" "$BASH_BIN" "$INSTALL" > "$THROW/det1.out" 2>&1
if grep -qF 'winget install --id EclipseAdoptium.Temurin.21.JRE -e' "$THROW/det1.out"; then ok "detection: uname MINGW64 selects Windows mode"; else bad "detection: no winget line: $(head -3 "$THROW/det1.out" | tr '\n' ';')"; fi
HOME="$WH" KIT_OS=linux PATH="$THROW/bin-uname" "$BASH_BIN" "$INSTALL" > "$THROW/det2.out" 2>&1
if grep -q '^sudo apt install -y' "$THROW/det2.out"; then ok "detection: KIT_OS=linux overrides uname"; else bad "detection: no apt line: $(head -3 "$THROW/det2.out" | tr '\n' ';')"; fi

winrun --uninstall > "$THROW/win-un.out" 2>&1
GOT=$?
expected "$THROW/win-before.json" > "$THROW/win-expected.json"
if [ "$GOT" -eq 0 ] && cmp -s "$THROW/win-expected.json" <(jq -S . "$WSET"); then ok "windows: --uninstall leaves the original plus the budget keys, no status line"; else bad "windows: --uninstall exit $GOT, settings differ: $(jq -c . "$WSET")"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
