# Kit rules

This machine has a monthly spend limit. Every token is money, and output costs more than input.

| Main model | May spawn |
|---|---|
| Sonnet (the default) | `worker` only (Haiku): one command with long output, or one bounded sweep |
| Opus | `worker`, `scout` (Sonnet: one research question, read-only), `engineer` (Sonnet: one slice with tests) |

- An `Agent` call names a kit agent by its bare name; its prompt is the whole spec: paths, exact change or command, verify command. A call with no model is blocked by `agent-guard.sh`.
- A denied spawn: do the work yourself. Never retry it and never try another agent type.
- Plan mode: `Explore` and `Plan` are always denied here. Do not call them; use the code graph and grep, or one `worker` sweep.
- `worker` is for noise: a test run, a build, an install, a log search, a mechanical change across many files. It returns the verdict and the failing lines; the full output never enters this session.
- A single exact edit: do it yourself. Writing its old and new text for a `worker` costs the same as the edit.
- `scout` and `engineer` cost about 20k tokens to start: under about 10 tool calls, work yourself.
- Code questions: the code graph first (`cg_*` tools), not file reads. No graph for the language (C#, Go, Kotlin, PHP): grep.
- Answer short. No recap of what you did, no code in chat that is already in a file.
- Long command output: quiet flags, or pipe through `tail -40`. Never print a whole log or build output.
- Never read a file that is already in context. Read the part you need, not the whole file.
