---
name: orchestrator
description: Use when a development task needs lite workflow dispatch, per-stage tool selection, recovery, or stage advancement through `plan.md` frontmatter.
---

# Orchestrator

orchestrator 只负责 lite workflow：`PLAN -> PLAN_REVIEW -> IMPLEMENT -> CODE_REVIEW -> TEST`。`DONE` 只是 frontmatter 终态标记，不是可执行 stage。

## 真相源

- 唯一阶段真相源：`docs/tasks/<task-id>/plan.md` frontmatter
- 可选附件：`docs/tasks/<task-id>/spec.md`
- TEST 产物：`docs/tasks/<task-id>/test.md`
- 共享运行时 mirror 只由 repo 脚本 `scripts/advance-stage.ps1` 重写；项目内入口是 `.assistant\entry\advance-stage.ps1`

## frontmatter 契约

```yaml
---
task_id: <task-id>
stage: PLAN | PLAN_REVIEW | IMPLEMENT | CODE_REVIEW | TEST | DONE
tool: claudecode | codex | gemini | none
updated: YYYY-MM-DD
---
```

规则：

- 非 `DONE` 阶段时，`tool` 只能是 `claudecode`、`codex`、`gemini`
- `DONE` 只能写 `tool: none`
- `tool` 表示“当前 stage 由哪个工具继续”，不是固定 profile

## 入口规则

1. 先判断请求是 `resume-current`、`switch-existing` 还是 `new-task`
2. 新任务先定 `task_id`，并让用户显式指定当前 stage 的 `tool`
3. 如果 `plan.md` 已存在，直接读 frontmatter 决定当前 `stage` 和 `tool`
4. 输入不足时才创建 `docs/tasks/<task-id>/spec.md`
5. 不再维护 `current-flow.md`、`handoff.md`、`implementation-notes.md`、`review.md`

## 调度规则

- `PLAN`：调用 `plan` skill，补齐 Clarification 和 User Confirmation
- `PLAN_REVIEW`：调用 `review` skill，写 `## Plan Review`
- `IMPLEMENT`：调用 `implement` skill，写 `## Implementation Notes`
- `CODE_REVIEW`：调用 `review` skill，写 `## Code Review`
- `TEST`：调用 `test` 或 `gemini-designer-main`，写 `test.md`

## 推进规则

stage 只通过下面这条命令推进：

```powershell
pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <task-id> -Tool <claudecode|codex|gemini>
```

规则：

- 只有 `TEST -> DONE` 可以省略 `-Tool`
- 其余推进都必须由用户显式指定下一阶段 `tool`
- 用户可以在任意 stage 边界切换 `tool`

它会转调 repo 内的 `advance-stage.ps1`，并先自动运行 validator，然后再：

- 更新 `plan.md` frontmatter 的 `stage`、`tool` 和 `updated`
- 重写 `运行时/tasks/<task-id>.md`
- 重写 `运行时/当前任务.md`
- 重写 `运行时/恢复索引.md`

## stop 条件

出现以下任一情况就停止并直接报告：

- `plan.md` 缺失或 frontmatter 不合法
- `stage` 或 `tool` 不在合法集合内
- PLAN 没有明确用户确认
- IMPLEMENT 没有新证据支撑回修
- TEST 缺 `## Conclusion` 或 `## Handoff`
- 当前 stage 的最新 run 没有合法 `verdict`
- 非 `DONE` 推进时用户没有指定下一阶段 `tool`

## 响应头

每次 orchestrator 响应先给这四行：

```text
task_id: <task-id>
stage: <stage>
tool: <tool>
advance_hint: pwsh -File .assistant\entry\advance-stage.ps1 -TaskId <task-id> -Tool <next-tool>
```

`TEST -> DONE` 时，`advance_hint` 可以省略 `-Tool`。

## References

- Gate rules: [references/gates.md](references/gates.md)
- Runbook: [references/runbook.md](references/runbook.md)
- State templates: [references/state-templates.md](references/state-templates.md)
- Tool selection: [references/default-tool-profiles.md](references/default-tool-profiles.md)
- Writing guide: [references/lite-writing-guide.md](references/lite-writing-guide.md)
