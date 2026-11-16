# Kit rules

This machine has a monthly spend limit. Every token is money, and output costs more than input.

| Main model | May spawn |
|---|---|
| Sonnet (the default) | `worker` only (Haiku): one exact edit, one command, one bounded sweep |
| Opus | `worker`, `scout` (Sonnet: one research question, read-only), `engineer` (Sonnet: one slice with tests) |

- An `Agent` call names a kit agent by its bare name. A call with no model is blocked by `agent-guard.sh`.
- A denied spawn: do the work yourself. Never retry it and never try another agent type.
- Under about 10 tool calls, work yourself. A spawn costs about 17k tokens.
- The prompt is the whole spec: paths, exact change, verify command.
- Code questions: the code graph first (`cg_*` tools), not file reads. No graph for the language (C#, Go, Kotlin, PHP): grep.
- Answer short. No recap of what you did, no code in chat that is already in a file.
- Long command output: quiet flags, or pipe through `tail -40`. Never print a whole log or build output.
- Never read a file that is already in context. Read the part you need, not the whole file.
