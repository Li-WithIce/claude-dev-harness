---
name: implement
description: Use when the task is in IMPLEMENT and code plus fresh implementation evidence must be appended to `plan.md`.
---

# Implement

IMPLEMENT 负责两件事：改代码，以及把本轮实现证据追加到 `docs/tasks/<task-id>/plan.md` 的 `## Implementation Notes`。

## 何时使用

- `plan.md` frontmatter 的 `stage` 是 `IMPLEMENT`
- 需要按已确认计划实现代码
- CODE_REVIEW 给出 `revise` 后，需要补新实现并追加新证据

## 硬约束

- 不写独立 `implementation-notes.md`
- 只追加新的 `### Run N`，不改旧 run
- 回修轮必须追加一条比最近一次 `Code Review` 更晚的 Implementation Notes run
- 不手改 frontmatter 的 `stage`

## Run 格式

```markdown
## Implementation Notes

### Run 2 · 2026-04-09 11:00 · runner: Codex
- changed: 修改的文件和行为
- tests: 实际跑过的命令；没跑就写 none
- risks: 本轮残留风险；没有就写 none
- next: 交给 CODE_REVIEW 关注什么
```

## 工作流程

1. 读取 `plan.md` 和可选 `spec.md`
2. 只实现当前计划要求的内容
3. 跑最小必要验证
4. 在 `## Implementation Notes` 末尾追加新 run
5. 推进到 `CODE_REVIEW` 前，必须让用户指定下一阶段 `tool`；如使用 profile，同步传 `-Profile` 和完整 `-Model`
6. 调用 `.assistant\entry\advance-stage.ps1 -TaskId <task-id> -Tool <next-tool>` 进入 `CODE_REVIEW`
7. 如需单独排查文档问题，再手动运行 `.assistant\entry\validate-lite-artifacts.ps1 -TaskId <task-id>`

## TodoWrite Milestones

- 适用：`claudecode`；其余 backend 视宿主实现而定。
- TodoWrite 是 Claude Code 内置 surface，不引入新依赖。
- milestone 是事件，不是签到点；一旦发现 blocker、计划外改动或验证无法完成，必须立刻汇报。
- 推荐最小节奏固定为：`context-loaded` → `code-edited` → `tests-run` → `notes-appended`。
- `notes-appended` 完成后，必须与最终的 stage callback / `team_send_message` / 用户回报配对，不能只停在本地 TodoWrite。
- 最小示例：
  - `context-loaded`：已读完 `plan.md`、`spec.md` 与目标文件
  - `code-edited`：本轮代码或文档改动已落盘
  - `tests-run`：本轮最小必要验证已执行并记录结果
  - `notes-appended`：`Implementation Notes` 已追加新 run，准备交给 `CODE_REVIEW`

## 不要做的事

- 不要重写旧 run
- 不要把 CODE_REVIEW 的结论写进 Implementation Notes
- 不要把 TEST 结论提前写进 `test.md`
