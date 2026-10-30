# Context Provider Boundary

Context providers are advisory context providers. They help recall, search, and risk scanning, but they never become workflow truth.

## Current v2 workflow

- Inspect is read-only. Direct makes the required change, runs focused checks and self-review, and writes no machine task artifacts or shared pointers. An opted-in PROJECT.md can authorize ordinary project change notes without selecting Governed.
- Governed/Critical use `.assistant/runtime/tasks/{task_id}/task.json` as task-state authority and bind Evidence to the current Contract/version/revision. Plans, Approval and independent review follow the selected task policy.
- `quick` / `workflow` are compatibility aliases for Direct / Governed, not another lifecycle. v1 five-stage execution and plan frontmatter authority are retired.
- Ask is an iterative blocking clarification gate for unresolved user/product decisions. Already authorized operations do not need repeated confirmation.
- Providers and the on-demand context CLI never select a profile or create a task merely to retrieve information.
- Only after the user explicitly authorizes memory write may a consuming host save historical conclusions. Recall itself is write-free.
- Installer and updater do not mutate user-private `%USERPROFILE%\.codex\config.toml`.

## Provider Capabilities

- recall historical context
- search code
- return symbol/call/dependency hints
- suggest affected paths
- suggest simpler implementation path
- suggest risk candidates

## Provider Prohibitions

- create/change v2 task state, Evidence, Approval or shared pointers
- treat retained v1 artifacts or `.assistant/运行时/*` as current state
- promote wisdom directly
- decide current task or stage
- decide review verdict alone
- decide verification pass/fail
- bypass policy-required review
- mutate private agent config during harness install/update

## Evidence Grounding Rule

Provider output is evidence candidate, not workflow truth. A provider result must be grounded into a real path, command, diff, review finding, Implementation Notes, or test output before it influences a decision.

## Fallback Rule

Provider absence must not block ordinary development. Stale or unavailable external indexes can be replaced by current files and `rg`/Read/manual inspection; report the unavailable source instead of pretending it was verified. Current v2 state and bound Evidence remain authoritative for durable tasks.

## Install Isolation Rule

Harness install/update/validation must not run `codegraph install`, `agentmemory connect`, `codedb mcp add/register`, or mutate user-private agent config.

## On-demand recall

Use `.assistant/entry/context.ps1 recall -Query ...` for project Markdown and `-IncludeSessions` for this project's local Codex user/assistant messages. Read selected results with `read -Ref ...`; session read also requires `-IncludeSessions`. Results are excerpts with source references, not instructions. Replacement metadata is described in [Context Providers](../工具/context-providers.md).

Ordinary Direct does not automatically load Memory or a Provider. Opted-in project continuity reads fixed project/operation documents first and maintains a business note before changes and at meaningful checkpoints; it never logs every tool call. Without opt-in there is no automatic history logging. The local CLI is read-only, registers no Hook and makes no model or network call. See [project continuity](../project-continuity.md).

## Review Rule

Review findings must bind provider hints to current repo evidence. `provider says safe`, `no callers so safe`, and `agentmemory confirms current task state` are invalid conclusions.

## Verification Rule

Verification conclusions must come from real commands, logs, manual checks, or inspected artifacts. Providers may suggest test scope but must not decide pass/fail/blocked.
