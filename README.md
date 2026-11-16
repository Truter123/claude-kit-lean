# claude-kit

One script that sets up Claude Code for a small monthly budget.

| Part | What it does |
|---|---|
| **Budget settings** | Sonnet as the main model, a one-hour prompt cache, a capped context, shorter command output. A key you already set is never changed. |
| **Status line** | Shows the spend at every moment: `Sonnet \| session $1.42 \| month $86 / $250 (pace $133) \| ctx 84k`. |
| **code-navigator** | Indexes a repo into a graph. Claude answers "where is X" and "who calls X" from the graph (`cg_*` tools), not by reading files. |
| **Agents and guards** | `worker` runs on Haiku, `scout` and `engineer` on Sonnet. A guard blocks every `Agent` call that names no model, or a model that is not cheaper than the caller. |

## Work machine (Windows, Git Bash)

1. Open Git Bash and install the two tools (skip one you already have). Then close and reopen Git Bash.
   ```bash
   winget install --id jqlang.jq -e
   winget install --id EclipseAdoptium.Temurin.21.JRE -e
   ```
2. Install the kit:
   ```bash
   git clone https://github.com/Truter123/claude-kit-lean ~/tools/claude-kit && ~/tools/claude-kit/install.sh
   ```
3. Restart Claude Code.
4. Check: `~/tools/claude-kit/install.sh --check` prints `[ok]` lines. A `[--]` line marked `not counted`
   is a hint, not an error.

When something is in the way:

- A tool is missing: the script prints its `winget` line and stops. Run the line, reopen Git Bash, run the
  script again. It is safe to run twice.
- `winget` is blocked: ask IT for jq and a Java 21 runtime.
- The script installs no software and never runs as administrator.

## First day (5 checks, about 10 minutes)

1. `~/tools/claude-kit/install.sh --check` ends with exit code 0 and its `model` line says `sonnet`. A
   `[--] model ...` line means IT set another model: the kit did not change it.
2. The real model and the one-hour cache: `claude -p "hello" --output-format json | jq '.modelUsage, .usage.cache_creation'`.
   The keys of the first block are the real model ids: one holds `sonnet-5-5`. An older Sonnet costs
   about twice as much in a long session (50% more per token, three times more per cached token): ask IT
   to set `ANTHROPIC_DEFAULT_SONNET_MODEL`. `ephemeral_1h_input_tokens` is above 0. If
   Claude Code prints an error about the cache instead, delete the line `"promptCacheTtl": "1h"` from
   `~/.claude/settings.json`.
3. Haiku is switched on: `claude --model haiku -p "say ok" --output-format json | jq '.modelUsage | keys'`
   prints an id that holds `haiku-5-5`. No answer: ask IT to enable Haiku in the cloud account; the
   `worker` agent needs it. An older Haiku costs about 10 times more: ask IT to set
   `ANTHROPIC_DEFAULT_HAIKU_MODEL`.
4. In a repo, in the second session: `/mcp` lists `code-navigator`. Ask "who calls X" about a real class;
   you see a `cg_*` tool call, not file reads.
5. After two prompts the status line shows `session $` above `0.00`. If it stays at `$0.00`, the provider
   reports no cost; note it and report it at home.

Two notes:

- Every spawn is denied (`capability graph: ...`): Claude then works alone and nothing breaks. Copy the
  message and report it at home.
- On Bedrock and Vertex the names `sonnet` and `haiku` can mean an older version; checks 2 and 3 show
  it. `/status` shows the real model too.

## Daily rules (5)

1. One task, one session. Task done, or back after more than one hour: `/clear`. An old session is sent
   again in full at the write price (about $0.50 at 130k tokens).
2. Never `/model` or `/effort` inside a session. Each change sends the whole conversation again at the
   full price. A hard question gets a new terminal: `claude --model opus`, ask, close.
3. Read the status line. Yellow `month`: you are above the pace. Red: 90% of the budget is gone. 250 USD
   is about 12 USD per working day. `ctx` above 100k: finish the step, then `/clear`.
4. Paste the 20 lines of a log that matter, not the file.
5. Say what "done" is: the file and the test command. Fewer turns cost less.

## The status line

`month` is the sum of all sessions on this machine in this calendar month. `pace` is what the spend may be
today when the budget is spent evenly. Green: under the pace. Yellow: over it. Red: 90% of the budget.

- It is Claude Code's own estimate at list price, for this machine only. The cloud bill is the truth.
- Another budget: set `KIT_BUDGET_USD` in the `env` block of `~/.claude/settings.json`.
- The numbers live in `~/.local/share/claude-kit/spend/<year-month>/`, one small file per session.
- A status line you already had is kept; the kit then shows nothing.
- `ctx` is the size of the last prompt in tokens; every new prompt sends that much again. Green: under
  100k. Yellow: from 100k. Red: from 150k.

## Spend report

`~/tools/claude-kit/bin/spend-report.sh 7` prints where the money of the last 7 days went: by model, by
prompt size, by pause length, whether the one-hour cache pays, and what coming back after a long break
cost. It reads token counts and times from the session files on this machine, never the text, and it costs
no tokens. Run it after the first week and report the output at home.

## What the install changes

- `~/.local/share/claude-kit/code-navigator/`: a shallow clone that holds the jar.
- `~/.claude/agents/{scout,engineer,worker}.md` and `~/.claude/KIT.md`: copies of the files in this repo.
  A file with the same name is kept as `<name>.bak-kit`. `~/.claude/.claude-kit-state` lists the copies.
- `~/.claude/CLAUDE.md`: one new line, `@KIT.md` (the rules for Claude, under 20 lines).
- `~/.claude/settings.json`: the kit's hook entries, the status line, and the keys of
  `settings/budget.json`. The file from before is kept as `settings.json.bak-kit`.

The budget keys are added only where the key is missing. The provider, the region, the login and the model
ids that IT set are never changed.

| Key | Value | Why |
|---|---|---|
| `model` | `sonnet` | Sonnet does most coding work at about half the list price of Opus. |
| `effortLevel` | `medium` | Thinking is billed as output. |
| `promptCacheTtl` | `1h` | On a cloud provider the default is 5 minutes. After a longer pause the whole conversation is sent again at the write price. Measured at home, 2026-11: it saves about 4 times what it costs. |
| `autoCompactWindow` | `200000` | A long session cannot grow past 200k tokens. |
| `awaySummaryEnabled`, `promptSuggestionEnabled` | `false` | No model calls for the recap and the grey suggestions. |
| `env.BASH_MAX_OUTPUT_LENGTH` | `15000` | Half the default length of command output. |
| `env.KIT_BUDGET_USD` | `250` | The budget for the status line. |
| `permissions.deny` | `.env` files | Secrets stay out of the prompt. |

In each git repo you open (never in the home directory) that has Java, TypeScript, Groovy, Dart, Python,
SQL or shell files, the session-start hook creates `navigators/` (the index) and `.mcp.json` (the server
entry). `navigators/` and a `.mcp.json` that the hook creates go into `.git/info/exclude`, so `git status`
stays clean and nothing is committed. An untracked `.mcp.json` that was already there gets the server
entry added and is not excluded. A `.mcp.json` that git tracks is never changed. C#, Go, Kotlin and PHP have no graph; there Claude searches with grep.

Before the first install at work, check that the company rules allow it: code-navigator builds an index of
the company code. The index stays on your machine, in `navigators/`.

## Linux and WSL

```bash
sudo apt install -y openjdk-21-jre-headless jq git
git clone https://github.com/Truter123/claude-kit-lean ~/tools/claude-kit && ~/tools/claude-kit/install.sh
```

The script never runs `sudo`. When a tool is missing or too old (git 2.31+, Java 21+), it prints the one
`apt` line to run and stops. In WSL keep the kit and your repos in the Linux file system (`~/...`), not
under `/mnt/c`: the index is a SQLite file, and SQLite there is slow.

## Flags and variables

| Flag | Effect |
|---|---|
| `--check` | one `[ok]` or `[--]` line per installed item; exit code 0 only when all are `[ok]` |
| `--uninstall` | remove what the kit added |
| `--with-rtk` | also run the RTK step (Linux and WSL only) |
| `--no-rtk` | accepted, does nothing (RTK is off by default) |
| `--help` | list the flags and variables |

| Variable | Effect |
|---|---|
| `CG_REPO` | the code-navigator git URL |
| `CG_REF` | the code-navigator branch or tag (default `master`). The value is remembered for later runs. |
| `KIT_OS` | `windows` or `linux`: overrides the system detection (for the tests) |
| `CLAUDE_CONFIG_DIR`, `XDG_DATA_HOME`, `XDG_CONFIG_HOME` | where the config and the data live |

## Models

- A main session on Sonnet may spawn `worker` only. On Opus it may also spawn `scout` and `engineer`.
- The guard reads the model of the running session. It does not know a model id that holds none of the
  names `haiku`, `sonnet`, `opus` (for example a Bedrock profile ARN); then every spawn is denied and
  Claude works alone.

## Optional: RTK

RTK shortens shell output before it reaches the model. It is off by default: an independent test
(JetBrains, 2026-07, 425 billed trials) found no saving, and RTK's own counter is not a proof. To try it on
Linux or WSL: `./install.sh --with-rtk` (needs `curl` and `python3`; it downloads an outside binary). Remove
it with `rtk init -g --uninstall`.

## Doc templates

`templates/` holds a `CLAUDE.md` skeleton, an ADR template and index, and rule and glossary files for
domain repos. Copy what the repo needs. See `templates/README.md` for which files a small repo and a
domain repo take, and for the five rules the templates enforce.

## Update and uninstall

```bash
cd ~/tools/claude-kit && git pull && ./install.sh     # update; also fetches the newest jar
~/tools/claude-kit/install.sh --uninstall             # remove
```

Restart Claude Code after both. The uninstall removes the copied files, the `@KIT.md` line, the kit's hook
entries and the kit's status line. It leaves the budget keys in `settings.json` (it prints them), the jar
and the spend numbers in `~/.local/share/claude-kit`, and in each repo `navigators/` and `.mcp.json`.

## Problems

- **The install fails on Windows.** Run `~/tools/claude-kit/install.sh --check`, copy the output and report
  it at home. Windows is simulated in the tests; the first real run is on your machine.
- **`/mcp` has no `code-navigator`.** Either the index is not built yet (wait for the first session to
  finish, then restart), or the repo has a tracked `.mcp.json`. In the second case add the server for
  yourself only, from the repo root. Windows:
  `claude mcp add -s local code-navigator -e CODE_NAVIGATOR_PROJECT="$(pwd -W)" -- java -jar "$(cygpath -m ~/.local/share/claude-kit/code-navigator/jars/code-navigator.jar)" serve`
  Linux: the same line with `$PWD` and the plain jar path.
- **The script warns that `HOME` differs from `%USERPROFILE%`.** Claude Code reads
  `%USERPROFILE%\.claude`. Run the script with `CLAUDE_CONFIG_DIR` set to that folder.

## Maintaining the kit

- `hooks/` holds copies. Their source is `~/.claude/hooks` on the home machine; refresh them with
  `bash sync-from-home.sh`, never by hand.
- `agents/`, `KIT.md`, `bin/`, `settings/` and `templates/` belong to this repo. Edit them here.
- Tests: `bash tests/guard.sh`, `bash tests/install.sh`, `bash tests/statusline.sh`,
  `bash tests/spend-report.sh`. They simulate Windows
  with a fake `cygpath` and a `jq` that writes CRLF. `tests/install.sh` runs in a throwaway `HOME`.
