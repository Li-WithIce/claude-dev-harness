# Lite Runbook

## 1. Bootstrap

1. 解析任务是 `resume-current`、`switch-existing` 还是 `new-task`
2. 为新任务选择 `task_id`，并让用户显式指定当前 stage 的 `tool`
3. 如无 `plan.md`，先创建 `docs/tasks/<task-id>/plan.md`
4. 输入不足时再补 `docs/tasks/<task-id>/spec.md`

## 2. Execute by Stage

- `PLAN`：写 Clarification、计划正文、Verification、Risks，并等待用户确认
- `PLAN_REVIEW`：追加一条 Plan Review run
- `IMPLEMENT`：改代码并追加一条 Implementation Notes run
- `CODE_REVIEW`：追加一条 Code Review run
- `TEST`：写 `test.md`

## 3. Advance

当前 stage 完成后执行：

```powershell
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <task-id> -Tool <claudecode|codex|gemini>
```

这个 workspace shim 会转调 repo 内的 `advance-stage.ps1`，并先自动运行 validator。

脚本负责：

- 更新 `plan.md` frontmatter
- 写入下一阶段 `tool`
- 刷新共享运行时 mirror

规则：

- 只有 `TEST -> DONE` 可以省略 `-Tool`
- 其余推进都必须由用户显式指定下一阶段 `tool`
- 用户可以在任意 stage 边界切换 tool

## 4. Loop Rules

- `PLAN_REVIEW verdict=revise` -> 回 `PLAN`
- `CODE_REVIEW verdict=revise` -> 回 `IMPLEMENT`
- `TEST conclusion=fail|blocked` -> 不自动回环，直接停止并报告

## 5. Terminal State

- `TEST conclusion=pass` -> `DONE`
- `DONE` 只写进 frontmatter，不再有独立 `HANDOFF` stage
- 交付摘要写在 `test.md` 的 `## Handoff`
