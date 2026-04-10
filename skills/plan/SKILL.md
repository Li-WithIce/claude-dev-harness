---
name: plan
description: Use when the task is in PLAN and you need to create or revise the authoritative `docs/tasks/<task-id>/plan.md`.
---

# Plan

PLAN 的唯一产物是 `docs/tasks/<task-id>/plan.md`。这个文件的 frontmatter 是 lite workflow 的唯一阶段真相源。

## 何时使用

- 当前 `plan.md` frontmatter 的 `stage` 是 `PLAN`
- 需要为新任务建首版 `plan.md`
- PLAN_REVIEW 退回后，需要重写计划并保留既有 review 历史

## 硬约束

- 路径固定：`docs/tasks/<task-id>/plan.md`
- frontmatter 只能包含：`task_id`、`stage`、`tool`、`updated`
- `stage` 在 PLAN 内保持 `PLAN`；不要手改到下一阶段，推进只走 `.assistant\entry\advance-stage.ps1`
- 新任务进入 PLAN 前，必须让用户显式指定当前 `tool`
- PLAN 阶段的 `tool` 只允许：`claudecode`、`codex`、`gemini`
- `spec.md` 只是可选附件，路径为 `docs/tasks/<task-id>/spec.md`
- 必须保留 append-only sections：`## Plan Review`、`## Implementation Notes`、`## Code Review`

## PLAN gate 必备内容

`plan.md` 至少包含以下 section：

- `## Clarification`
- `## User Confirmation`
- `## Plan`
- `## Verification`
- `## Risks`
- `## Plan Review`
- `## Implementation Notes`
- `## Code Review`

`## Clarification` 必须逐项写清：

- 验收标准
- 非目标
- 受影响目录 / 模块
- 回滚或兼容性约束
- `ui: <expectation | not-applicable>`

`## User Confirmation` 必须使用这条机器可读字段：

```markdown
## User Confirmation
- status: draft | confirmed
```

没有明确确认前写 `draft`；用户确认后改成 `confirmed`，然后再调用 `advance-stage.ps1`。

## 推荐骨架

```markdown
---
task_id: <task-id>
stage: PLAN
tool: claudecode
updated: 2026-04-09
---
# <Task Title>

## Clarification
- 验收标准: ...
- 非目标: ...
- 受影响目录: ...
- 回滚策略: ...
- ui: not-applicable

## User Confirmation
- status: draft

## Plan
- TODO 1: ...
- TODO 2: ...

## Verification
- `pwsh -File tests/...`

## Risks
- ...

## Plan Review

## Implementation Notes

## Code Review
```

## 工作方式

1. 先读已批准输入和可选 `spec.md`
2. 把 Clarification 补齐到能执行的粒度
3. 写出精确文件路径、验证命令和风险
4. 用户确认后，把 `User Confirmation` 改成 `confirmed`
5. 推进到 `PLAN_REVIEW` 前，必须让用户指定下一阶段 `tool`
6. 只在 gate 满足后执行 `.assistant\entry\advance-stage.ps1 -TaskId <task-id> -Tool <next-tool>`
7. 如需单独排查文档问题，再手动运行 `.assistant\entry\validate-lite-artifacts.ps1 -TaskId <task-id>`

## 不要做的事

- 不要写 `docs/<task-id>/...`
- 不要新建 `current-flow.md`、`review.md`、`implementation-notes.md`、`handoff.md`
- 不要覆盖历史 review / implementation runs

## Reference

- 写作规范: [../orchestrator/references/lite-writing-guide.md](../orchestrator/references/lite-writing-guide.md)
