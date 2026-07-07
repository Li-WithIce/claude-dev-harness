# Context Provider Boundary

Context providers are advisory context providers. They help recall, search, and risk scanning, but they never become workflow truth.

## Baseline Invariants

- Workflow stays `PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST`; `DONE` is only a frontmatter terminal state.
- `quick` does not create `docs/tasks/<task-id>/` and does not update shared pointers.
- `workflow` enters `entry-router -> orchestrator` and writes task artifacts.
- `ask` asks one minimal question and does not load workflow skills.
- `plan.md` frontmatter is the only stage truth.
- `.assistant/运行时/*` is derived runtime view, not provider state.
- Pending wisdom goes to `.assistant/运行时/收件箱.md` before triage or promotion.
- Installer and updater do not mutate user-private `%USERPROFILE%\.codex\config.toml`.

## Provider Capabilities

- recall historical context
- search code
- return symbol/call/dependency hints
- suggest affected paths
- suggest simpler implementation path
- suggest risk candidates

## Provider Prohibitions

- create/change stages
- write `docs/tasks/<task-id>/plan.md` frontmatter
- write `docs/tasks/<task-id>/test.md` conclusion
- write `.assistant/运行时/*`
- promote wisdom directly
- decide current task or stage
- decide review verdict alone
- decide TEST pass/fail
- bypass PLAN_REVIEW/CODE_REVIEW
- mutate private agent config during harness install/update

## Evidence Grounding Rule

Provider output is evidence candidate, not workflow truth. A provider result must be grounded into a real path, command, diff, review finding, Implementation Notes, or test output before it influences a decision.

## Fallback Rule

Provider absence must not block quick mode or normal workflow. Stale, unavailable, or conflicting provider output falls back to current repo files, `rg`/Read/manual inspection, `.assistant`, and `docs/tasks` truth.

## Install Isolation Rule

Harness install/update/validation must not run `codegraph install`, `agentmemory connect`, `codedb mcp add/register`, or mutate user-private agent config.

## Stage Integration Rule

Provider guidance is loaded only through stage references and explicit triggers. It does not add stages, frontmatter fields, runtime pointers, or hard validator gates.

## Review Rule

PLAN_REVIEW/CODE_REVIEW findings must bind provider hints to current repo evidence. `provider says safe`, `no callers so safe`, and `agentmemory confirms current stage` are invalid conclusions.

## TEST Rule

TEST conclusion must come from real commands, logs, manual checks, or inspected artifacts. Providers may suggest test scope but must not decide pass/fail/blocked.
