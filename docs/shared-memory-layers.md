# Shared Memory Layers

## Layers

| Layer | Path Prefix | Truth Level | Primary Writer | Allowed Readers |
|---|---|---|---|---|
| artifact | `docs/tasks/{task_id}/` | authoritative | current task owner | all runners, reviewer, tester, recovery tools |
| runtime | `.assistant/运行时/` | mixed: pointer/task-state authoritative, index/interrupted derived | current `entry_host` for shared pointer files; task owner for `运行时/tasks/<task-id>.md` | all runners, health/repair/recovery tools |
| config | `.assistant/配置/` | authoritative | user-confirmed maintenance only | all runners |
| workflow | `.assistant/工作流/` | authoritative protocol docs | harness maintainers | all runners |

### Layer Notes

- `docs/tasks/{task_id}/plan.md` frontmatter `stage/tool` is the only task-stage truth source.
- `.assistant/运行时/tasks/<task-id>.md` is the task-runtime mirror derived from task artifacts and may be read for recovery.
- `.assistant/运行时/当前任务.md` is the shared pointer for the currently active task.
- `.assistant/运行时/恢复索引.md` and `.assistant/运行时/中断任务.md` are derived views and must not become stronger than their sources.
- team task-board state is a mirror for UI/orchestration only; it does not author vault fields.

## Writeback Ladder

1. Write `docs/tasks/{task_id}/plan.md` frontmatter.
2. Mirror to `.assistant/运行时/tasks/<task-id>.md`.
3. Refresh `.assistant/运行时/当前任务.md` only when the task is already active or explicitly activated.
4. Refresh `.assistant/运行时/恢复索引.md`.

Background advances never replace the current pointer. Active `DONE` writes the canonical idle pointer; background `DONE` leaves current unchanged. Any runtime-ladder failure stops later writes, returns nonzero, and appends an open `[writeback-fallback]` after locks are released. A successful `-SyncOnly` releases the runtime mutex, reacquires it in stage-to-runtime order while retaining the same-task stage mutex, and clears matching fallback rows before releasing the stage mutex. Resume/switch readers inspect fallback rows before normal runtime pointers.

### Direction Rules

- Each step may read the previous step as input.
- Reverse writes are forbidden.
- Shared pointer files are owned by the current `entry_host`.
- Every advance/sync/activate uses caller-supplied `ExpectedStage` compare-and-swap; `SyncOnly` changes no artifact stage, while `ActivateCurrent` is the only explicit current switch.
- `team_task_update` may mirror vault state after writeback, but never writes back into the vault.

## Forbidden Reverse Edges

- `.assistant/运行时/当前任务.md -> docs/tasks/{task_id}/plan.md`
- `.assistant/运行时/恢复索引.md -> .assistant/运行时/当前任务.md`
- `.assistant/运行时/中断任务.md -> docs/tasks/{task_id}/plan.md`
- `team task-board -> .assistant/运行时/*`
- `.assistant/配置/*.md -> .assistant/运行时/*`
