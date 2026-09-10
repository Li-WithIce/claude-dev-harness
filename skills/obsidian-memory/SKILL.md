---
name: obsidian-memory
description: Use only for explicitly needed installed shared-memory recall or user-authorized memory maintenance; never for ordinary task routing or recovery.
---

# Obsidian Memory

Claude and Codex may share the installed optional memory vault at
`{VAULT_PATH}`. This capability is not an entry router, lifecycle owner or
task-state authority.

## Read boundary

- Load only when the installed memory feature is explicitly needed. A request
  to continue or recover a task alone does not activate Memory.
- Use stable configuration/preferences and explicitly relevant historical
  memory. Current repository facts and current user instructions take priority.
- Ordinary task recovery uses `.assistant/entry/task.ps1 status`, not legacy
  pointers, plans, runtime mirrors, orchestration flows or memory notes.
- Explicit legacy history/health inspection is maintenance only. It cannot
  resume, create or advance a task, or authorize a pointer write.

## Authorized memory writes

- Save/promote stable memory only when the user explicitly requests it.
- Keep existing append-only candidate/archive/wisdom history. Use the bounded
  maintenance commands and preserve source entries when classifying them.
- Actionable inbox items require explicit capture authority; interactive
  ambiguity is a question, not an inbox write.
- Never update lifecycle pointers or task state through Memory. All v2 state
  changes belong to the Kernel task APIs with their Contract/version/Approval.
- Never copy secrets into memory, task artifacts, Evidence, logs or reports.
- Internal failed writes belong in `.assistant/runtime/failed-writes`, not a
  business inbox.

## Optional maintenance tooling

The installed scripts for memory-health, candidate archive, triage and report
generation remain opt-in maintenance. Their retained legacy-history checks are
not ordinary Runtime or evidence that a v1 workflow is supported. Do not invoke
repair of a retired lifecycle mirror; preserve it as history.

`memory-maintain` runs candidate archive only. Repair is retired; report and
health are `NOT_RUN` unless directly requested through their diagnostic
commands. These diagnostics are explicitly historical-v1-only: a fresh v2
installation reports `NOT_APPLICABLE`, never a v2 health pass or a request to
recreate old mirrors. They do not recursively scan agent homes. Inbox capture
keeps an explicit TaskId unchanged and uses `unknown` when it is omitted,
without reading historical pointers or flows.

## agentmemory compatibility

agentmemory is an optional read-only historical recall sidecar. It never
controls task status, review verdicts or Evidence, promotes memory without user
authorization, or runs connect during Harness installation.
