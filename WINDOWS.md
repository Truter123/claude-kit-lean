# Instructions for Claude Code: install claude-kit on native Windows (Git Bash)

You are Claude Code on a Windows work machine. The user runs Claude Code natively, with Git Bash; there is no
WSL. `install.sh` in this repo supports only Linux/WSL, so do **not** run it. Do the install by hand with the
steps below. Use the Edit/Write tools for JSON and TOML (Git Bash has no `jq` until step 1).

Rules while you do this:
- Ask the user before every `winget install` and before you change `~/.claude/settings.json`.
- Never install anything else, never run an installer you downloaded with `curl`.
- After each step, run its check. Stop and report if a check fails; do not guess a workaround.
- Paths: in Git Bash, `~` is `/c/Users/<user>`. Write paths into JSON as `C:/Users/<user>/...` (forward
  slashes). Get them with `cygpath -m <path>` or `pwd -W`.

Names used below:
- `KIT` = this repo, e.g. `C:/Users/<user>/tools/claude-kit` (`cygpath -m ~/tools/claude-kit`)
- `CFG` = `~/.claude` (Claude Code reads `%USERPROFILE%\.claude`; check that `cygpath -m ~` equals
  `cygpath -m "$USERPROFILE"`, otherwise stop and tell the user)
- `JAR` = `C:/Users/<user>/.local/share/claude-kit/code-navigator/jars/code-navigator.jar`

## 1. Tools

Check: `git --version`, `java -version` (needs 21 or newer), `jq --version`, `rtk --version`.
For each one that is missing, ask the user, then:

```bash
winget install --id jqlang.jq -e
winget install --id EclipseAdoptium.Temurin.21.JRE -e
winget install --id rtk-ai.rtk -e
```

winget changes `PATH` only for new terminals. Tell the user to close and reopen Git Bash and Claude Code, then
continue from this step. If winget is blocked by company policy, stop and tell the user (IT has to install
them).

Check: all four commands print a version; `java -version` says 21 or more.

## 2. code-navigator jar

```bash
mkdir -p ~/.local/share/claude-kit
git clone --depth 1 https://github.com/Truter123/code-navigator ~/.local/share/claude-kit/code-navigator
```

Update later: `git -C ~/.local/share/claude-kit/code-navigator pull --depth 1`.

Check: `java -jar "$(cygpath -m ~/.local/share/claude-kit/code-navigator/jars/code-navigator.jar)" --help`
lists `init`, `sync`, `serve`, `mark-dirty`, `sync-if-dirty`.

## 3. Agents and rules (copies, not links)

Links do not work reliably on Windows. Copy:

1. For each of `scout.md`, `engineer.md`, `worker.md`: if `~/.claude/agents/<name>` exists and differs from
   `KIT/agents/<name>`, move it to `<name>.bak-kit` first. Then copy `KIT/agents/<name>` there.
2. Copy `KIT/KIT.md` to `~/.claude/KIT.md`.
3. Add the line `@KIT.md` to the end of `~/.claude/CLAUDE.md` (create the file if missing; add it once).

Check: `cmp` of each copy with its source prints nothing; `grep -cx '@KIT.md' ~/.claude/CLAUDE.md` prints `1`.

## 4. Hooks in settings.json

Copy `~/.claude/settings.json` to `~/.claude/settings.json.bak-kit` first (if the file is missing, create it
as `{}` and back that up). Then merge these entries into its `"hooks"` object. Keep every existing key and
hook. Replace `<KIT>` and `<JAR>` with the real `C:/...` paths. Skip an entry whose `command` is already there.

```json
{
  "PreToolUse": [
    { "matcher": "Agent", "hooks": [ { "type": "command", "command": "bash \"<KIT>/hooks/agent-guard.sh\"" } ] },
    { "matcher": "*", "hooks": [ { "type": "command", "command": "bash \"<KIT>/hooks/budget-guard.sh\"" } ] }
  ],
  "SubagentStart": [ { "hooks": [ { "type": "command", "command": "bash \"<KIT>/hooks/agent-registry.sh\"" } ] } ],
  "SubagentStop":  [ { "hooks": [ { "type": "command", "command": "bash \"<KIT>/hooks/agent-registry.sh\"" } ] } ],
  "SessionEnd":    [ { "hooks": [ { "type": "command", "command": "bash \"<KIT>/hooks/agent-registry.sh\"" } ] } ],
  "SessionStart": [ { "hooks": [ { "type": "command", "async": true,
    "command": "[ -f \"$PWD/navigators/code/code-navigator.db\" ] && timeout 900 java -jar \"<JAR>\" sync \"$(pwd -W)\" >/dev/null 2>&1; true" } ] } ],
  "PostToolUse": [ { "matcher": "Edit|Write|MultiEdit|NotebookEdit", "hooks": [ { "type": "command", "async": true,
    "command": "[ -f \"$PWD/navigators/code/code-navigator.db\" ] && java -jar \"<JAR>\" mark-dirty \"$(pwd -W)\"; true" } ] } ],
  "Stop": [ { "matcher": "", "hooks": [ { "type": "command", "async": true,
    "command": "[ -f \"$PWD/navigators/code/.dirty\" ] && timeout 600 java -jar \"<JAR>\" sync-if-dirty \"$(pwd -W)\"; true" } ] } ]
}
```

On Windows the kit's `cg-sync.sh` is **not** used: it writes `.mcp.json` with Git Bash paths. Step 6 wires
each repo instead, without any file in the repo.

Check: `jq . ~/.claude/settings.json` parses; `jq '[.hooks[][]] | length' ~/.claude/settings.json` grew by 8.

## 5. RTK

```bash
rtk init -g --auto-patch
```

Then edit `$(cygpath -u "$APPDATA")/rtk/config.toml` (create it if missing) so it holds, each under its own
section header (add a missing section, change a key that is there):

```toml
[hooks]
exclude_commands = ["git diff"]

[awareness]
level = "full"

[telemetry]
enabled = false
```

Run `rtk init -g --auto-patch` again; it rewrites `~/.claude/RTK.md` for level `full`.

Check: `rtk init --show` prints `[ok] Hook: rtk hook claude`; `grep -c 'Prefix external programs'
~/.claude/RTK.md` prints `1`.

## 6. Per repo: index and MCP server

Run in each repo the user names (Java, TypeScript, Groovy, Dart, Python, SQL or shell code). Nothing here
changes a tracked file or adds an untracked one:

```bash
cd <repo>
grep -qx 'navigators/' .git/info/exclude || echo 'navigators/' >> .git/info/exclude
java -jar "<JAR>" init "$(pwd -W)"
claude mcp add -s local code-navigator -e CODE_NAVIGATOR_PROJECT="$(pwd -W)" -- java -jar "<JAR>" serve
```

`-s local` stores the server in `~/.claude.json` for this folder only, not in the repo. The first `init` of a
large repo can take a few minutes.

Check: `git status --short` shows nothing new; `claude mcp list` shows `code-navigator` as connected.

## 7. Self-test

```bash
bash "$(cygpath -u '<KIT>')/tests/guard.sh"
```

It must end with `0 failed`. If it fails, show the user the failing lines. A likely cause on Windows is a
`\r` at the end of `jq` output (`printf '{"a":"b"}' | jq -r .a | od -c` shows `\r`). Then the fix is `jq -b`
in the hook scripts. Make it only in this repo, on a new branch, and tell the user. The hooks are copies of
the user's home machine scripts, and the fix must go back there too.

## 8. Done: tell the user to restart Claude Code, then check

- `/mcp` in a wired repo lists `code-navigator`.
- Ask "who calls <a real class>": the answer uses a `cg_*` tool, not file reads.
- An `Agent` call without a model is blocked (the guard works).
- After an hour of work, `rtk gain` shows saved tokens.

## Uninstall

1. Copy `~/.claude/settings.json.bak-kit` back to `~/.claude/settings.json`. If you changed settings since,
   remove only the 8 entries from step 4 instead.
2. Delete the three agent copies and `~/.claude/KIT.md`; move any `*.bak-kit` back. Remove the `@KIT.md` line.
3. In each repo: `claude mcp remove code-navigator -s local`; the `navigators/` folder can be deleted.
4. `rtk init -g --uninstall`; `winget uninstall rtk-ai.rtk` if wanted.
