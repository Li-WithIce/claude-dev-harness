# Thin Harness v2 task state

## Purpose and truth source

Durable Governed and Critical work uses `task-state/v2`. The canonical task document is the only lifecycle truth source; events, Evidence, Approval, audit, current pointer, and recovery index are bound records or derived views, not parallel state.

Direct and Inspect work do not create this layout. Existing v1 `plan.md` tasks continue through the five-stage workflow and are never converted implicitly.

## Workspace layout

```text
.assistant/runtime/
  current.json
  locks/
  failed-writes/
  tasks/<task-id>/
    task.json
    events.jsonl
```

Task Evidence and Approval are published at their canonical workspace-contained paths. Transaction journals live under `failed-writes`; they are not routed through the business inbox or Memory.

Migration may stage `.migration-<task-id>-<32 lowercase hex>` below the tasks directory. Recovery ignores and preserves only that strict internal form. Other unknown directories remain fail-closed, and no recovery read deletes residual data.

## Lifecycle

The legal statuses are:

`blocked | ready | running | verifying | paused | done | failed | cancelled`

The transition table is implemented once in `Harness.TaskState.psm1`:

- blocked -> ready after a revised Requirement Contract;
- ready -> running or cancelled;
- running -> verifying, blocked, failed, or paused;
- verifying -> done, running, paused, or failed;
- paused -> running, verifying, or cancelled;
- failed -> running;
- done and cancelled are terminal.

Generic transition cannot claim `done`. Completion requires canonical Evidence and, when policy requires it, current Approval and governance artifacts. An active task clears `current.json` when it reaches done or cancelled.

## Concurrency and atomicity

Every mutation requires `ExpectedVersion`. The per-task mutex serializes writers; a stale version, illegal transition, occupied current pointer, pending transaction, path escape, or malformed record fails before publication.

A mutation is expressed as a bounded journal of contained write/delete steps. Atomic replacement preserves preimages, append-only events, and replay metadata. A fault records a workspace-bound transaction id; `task.ps1 replay` is idempotent and archives a recovered journal. Unknown or tampered journal paths are rejected.

The current pointer is optional and singular. Background tasks do not steal it. Resume is read-only; only explicit `resume-and-execute -TaskId ... -ExpectedVersion ...` can mutate state and activate a resumable task.

## Evidence, Approval, and governance

- `evidence/v1` binds task id/version, Requirement Contract digest, repository revision, command exit codes, records, coverage, and conclusion.
- pass plus nonzero exit, stale digest/revision, path escape, or incomplete coverage cannot complete a task.
- Approval binds the exact task version, contract digest, type, scope, approver, time, expiry, and status. Scope or version change makes it stale.
- Required audit binds implementer/reviewer actor and context plus the Evidence digest. A pass audit cannot contain a P0/P1 blocking finding.

These records are prerequisites to a state transition; they never overwrite `task.json` as a second truth source.

## Read and recovery behavior

`task.ps1 status` and bare `resume` are zero-write. The recovery index enumerates nonterminal tasks, validates the pointer against a live task/version, and reports pending failed-write journals. Terminal tasks are counted but not resumable.

Memory and Team are optional consumers. Core recovery works from the runtime task documents alone and does not require Obsidian, an inbox, provider indexes, or prompt injection.

## Compatibility, validation, and rollback

Protocol detection is artifact-first: an existing v2 `task.json` stays v2; a legal v1 `plan.md` stays v1. Explicit protocol conflicts fail closed. Migration uses dry-run digest checks and atomic directory publication, preserves the v1 artifact read-only, and never deletes v2 data to perform rollback.

`tests/verify-v2-task-state.ps1`, `tests/verify-v2-evidence.ps1`, `tests/verify-v2-approval.ps1`, `tests/verify-v2-governed-audit.ps1`, `tests/verify-v2-runtime-memory-decoupling.ps1`, and migration/coexistence tests cover these contracts.

Rollback sets `HARNESS_PROTOCOL=v1` for new work or reverts the relevant implementation commit. Existing v2 runtime remains available for read-only diagnosis and explicit recovery; existing v1 tasks, installation, update, uninstall, recovery, and validation remain intact.
