# claude-kit

Three things that cut Claude Code token use, installed by one script.

| Part | What it does |
|---|---|
| **code-navigator** | Indexes a repo into a graph. Claude answers "where is X" and "who calls X" from the graph (`cg_*` tools), not by reading files. |
| **RTK** | Shortens shell output (`git`, test runs, `ls`, `grep`) before it reaches the model. |
| **Three agents** | `scout` and `engineer` run on Sonnet, `worker` on Haiku, so delegated work does not run on Opus. A guard blocks every `Agent` call that names no model, so a spawn never inherits Opus by default. |

## Install

Native Windows with Git Bash (no WSL): do not run `install.sh`. Clone the repo in Git Bash, start Claude
Code in it and say: "Follow WINDOWS.md". Claude does the install step by step and asks before each change.

In WSL (Ubuntu):

```bash
sudo apt install -y openjdk-21-jre-headless jq python3 git curl
git clone https://github.com/Truter123/claude-kit-lean ~/tools/claude-kit
~/tools/claude-kit/install.sh
```

Then restart Claude Code.

The repo is private, so the clone asks for your GitHub login. The simple way is to log in first:
`sudo apt install -y gh && gh auth login` (choose HTTPS; git then uses that login).

The script never runs `sudo`. When a tool is missing or too old (git 2.31+, Java 21+), it prints the
one `apt` line to run and stops. It is safe to run twice.

| Flag | Effect |
|---|---|
| `--check` | one `[ok]` or `[--]` line per installed item; exit code 0 only when all are `[ok]` |
| `--no-rtk` | skip the RTK step |
| `--uninstall` | remove what the kit added (RTK stays) |
| `--help` | list the flags and variables |

`CG_REF` picks the code-navigator branch or tag (default `master`):
`CG_REF=code-only-navigator ~/tools/claude-kit/install.sh`

## What the install changes

- `~/.local/share/claude-kit/code-navigator/`: a shallow clone that holds the jar.
- `~/.claude/agents/{scout,engineer,worker}.md` and `~/.claude/KIT.md`: links into this repo. A file
  with the same name is kept as `<name>.bak-kit`.
- `~/.claude/CLAUDE.md`: one new line, `@KIT.md` (the delegation rules).
- `~/.claude/settings.json`: eight hook entries. The file from before is kept as
  `settings.json.bak-kit`.
- RTK: the binary in `~/.local/bin`, its Bash hook, and three settings in
  `~/.config/rtk/config.toml`: `exclude_commands = ["git diff"]`, awareness `full`, telemetry
  `enabled = false`.

In each git repo you open (never in `$HOME`) that has Java, TypeScript, Groovy, Dart, Python, SQL or
shell files, the session-start hook creates `navigators/` (the index) and `.mcp.json` (the server
entry). `navigators/` and a `.mcp.json` that the hook creates go into `.git/info/exclude`, so
`git status` stays clean and nothing is committed. An untracked `.mcp.json` that was already there
gets the server entry added. A `.mcp.json` that git tracks is never changed.

C#, Go, Kotlin and PHP have no graph. There the agents search with grep, and RTK still works.

## WSL notes

- Run Claude Code inside WSL. Keep the kit and your repos in the Linux file system (`~/...`), not
  under `/mnt/c`: the index is a SQLite file, and SQLite on `/mnt/c` is slow. The installer warns
  when the kit is under `/mnt/`.
- Clone the kit inside WSL, not with Git for Windows. The scripts need LF line endings
  (`.gitattributes` keeps them).
- `rtk: command not found` after the install: add `~/.local/bin` to `PATH`. The installer prints
  the line.

## First-session checklist

Before the install:

- [ ] The company rules allow it. RTK is an outside binary, downloaded by its own installer
      (`curl ... | sh`). code-navigator builds an index of the company code; the index stays on your
      machine, in `navigators/`.

At work:

- [ ] `~/tools/claude-kit/install.sh --check` prints only `[ok]` lines.
- [ ] `/mcp` lists `code-navigator` in an indexed repo. The first session in a repo builds the
      index; the server is there from the second session. If Claude Code asks about the server from
      `.mcp.json`, accept it.
- [ ] Ask "who calls X" about a real class. You see a `cg_*` tool call, not file reads.
- [ ] After an hour of work, `rtk gain` shows saved tokens.

## Models

- A main session on Opus may spawn all three agents. On Sonnet, only `worker`.
- An `Agent` call that names no model is blocked. A kit agent brings its own model. The guard does
  not stop a built-in agent called with a cheaper model; `KIT.md` tells Claude to use the kit agents.
- The guard reads the model of the running session, so a `/model` switch counts at once.

## Update

```bash
cd ~/tools/claude-kit && git pull && ./install.sh
```

This also fetches the newest jar on `CG_REF`. Restart Claude Code.

## Uninstall

```bash
~/tools/claude-kit/install.sh --uninstall
```

It removes the links, the `@KIT.md` line and the kit's hook entries. It leaves:

- RTK: remove it with `rtk init -g --uninstall`.
- The jar: delete `~/.local/share/claude-kit`.
- In each repo: `navigators/` and `.mcp.json` (both untracked).

## Problems

- **`/mcp` has no `code-navigator`.** Either the index is not built yet (wait for the first session
  to finish, then restart), or the repo has a tracked `.mcp.json`. In the second case add the server
  for yourself only, from the repo root:
  `claude mcp add code-navigator -e CODE_NAVIGATOR_PROJECT="$PWD" -- java -jar ~/.local/share/claude-kit/code-navigator/jars/code-navigator.jar serve`
- **A command is refused once with "a hook changed this call's input".** Claude should type the
  `rtk` prefix itself. Check that `~/.claude/RTK.md` says "Prefix external programs with `rtk`". If
  it does not, run `./install.sh` again.

## Maintaining the kit

- `hooks/` holds copies. Their source is `~/.claude/hooks` on the home machine; refresh them with
  `bash sync-from-home.sh`, never by hand.
- `agents/` and `KIT.md` belong to this repo. Edit them here.
- Tests: `bash tests/guard.sh` and `bash tests/install.sh` (the second one runs in a throwaway
  `HOME`).
