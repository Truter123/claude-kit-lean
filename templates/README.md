# Doc templates

Copy what the repo needs, fill the `<placeholders>`, delete the `<!-- comments -->`.

| Repo | Takes |
|---|---|
| Small or tool repo | `CLAUDE.md` + `adr/` (`0000-template.md`, `README.md`) |
| Domain repo | the same, plus `.claude/rules/rules.md` and `.claude/rules/glossary.md` |

Not in the set: `CONTEXT.md`, a digest beside a catalogue, `docs/domain/` (only if a person outside Claude reads it).

## Five rules (each is also written in the file it governs)

1. No `CONTEXT.md`; one fact lives in one file, other files point to it. Why: copies drift apart.
2. No number the repo can count in an always-loaded file (ADR count, migration number, library versions, test count, host count). Why: these went stale in most of 18 audited repos.
3. No tool names (MCP tools, `cg_*`) in a project `CLAUDE.md`; tools describe themselves. Why: one rename broke three repos.
4. Every ADR has a `status:` line; a later ADR that changes an old one, also in part, adds `amended-by: NNNN` to the old one's frontmatter; an ADR body is never rewritten. Why: history stays true and a reader finds the newer decision.
5. One rules file, one line per rule (`BR-NNN`, rule, reason, source); never a digest beside a catalogue. Why: one digest grew to 82% of its catalogue and held rules the catalogue lacked.
