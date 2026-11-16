<!-- Rule 2: no number the repo can count in this file (ADR count, migration number, versions, test count, host count). -->
<!-- Rule 3: no tool names (MCP tools, cg_*) in this file; tools describe themselves. -->
<!-- Rule 1: no CONTEXT.md; a fact lives in one file, here only a pointer. Limit: 60 lines. Delete comments when filled. -->
# <app name>
<One sentence: what it does and for whom.> Stack: <language / framework, frontend, database>.

## Commands
- build: `<build and test command>`
- one test: `<single-test command>`

## Conventions (new code)
- Copy the shape of `<path/to/Service>` and `<path/to/Controller>` (the reference slice).
- <one convention Claude would otherwise get wrong>

## Known mess (do not copy, do not fix unasked)
- `<legacy path>/**` <what is wrong>: leave it.
- `<other path>/**` <old pattern>: new code uses <new pattern>.

## Hard rules
- No production data in prompts, tests or docs (<personal identifiers, names, policy numbers>).
- Decisions: `adr/README.md`. Read the ADR before changing what it covers.
<!-- Domain repos only, delete these two lines otherwise: -->
- Business rules: `.claude/rules/rules.md`. Code and a rule disagree: stop and ask.
- Terms: `.claude/rules/glossary.md` binds names in code, API and UI.
