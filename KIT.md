# Delegation rules

Every `Agent` call names a kit agent by its bare name. A bare call is blocked by `agent-guard.sh`.

| Agent | Model | For |
|---|---|---|
| `scout` | sonnet | one research question, read-only |
| `engineer` | sonnet | one implementation slice with tests |
| `worker` | haiku | one exact edit, one command, one bounded sweep |

- Under about 10 tool calls, work yourself. A spawn costs about 17k tokens.
- Code questions: `cg_node` / `cg_search` inline. Research that needs more than a few calls goes to `scout`.
- No graph for the language (C#, Go, Kotlin, PHP): "where is X" goes to `worker`, "how does X work" to `scout`.
- The prompt is the whole spec: paths, exact change, verify command. A failed `worker` moves up to `engineer`.
- Main loop on Opus may spawn all three. On Sonnet, only `worker`.
