---
name: review
description: Use when the task is in PLAN_REVIEW or CODE_REVIEW and a new append-only review run must be written into `plan.md`.
---

# Review

这个 skill 同时服务 `PLAN_REVIEW` 和 `CODE_REVIEW`。它不再产出独立 `review.md`，而是把审查结论追加到 `plan.md`。

## 何时使用

- `plan.md` frontmatter 的 `stage` 是 `PLAN_REVIEW`
- `plan.md` frontmatter 的 `stage` 是 `CODE_REVIEW`

## 当前阶段对应关系

- `PLAN_REVIEW`：追加到 `## Plan Review`
- `CODE_REVIEW`：追加到 `## Code Review`

## Run 格式

```markdown
### Run 1 · 2026-04-09 10:30 · runner: Codex
- verdict: pass | revise
- score.completeness: 85
- score.consistency: 82
- score.accuracy: 88
- score.depth: 80
- findings:
  - P1: ...
  - P2: ...
- next: 下一步动作；无则写 none
```

`advance-stage.ps1` 只读取最新一条 run 的 `- verdict:`，所以字段名不要变。
只有在 validator 以 `-Quality` 模式运行时，才要求录入 4-dim score；旧 run 未录入时只会收到 warning。

## 审查重点

### PLAN_REVIEW

- Clarification 是否完整
- User Confirmation 是否已经 `confirmed`
- 计划粒度是否足够指导实现和验证
- 风险和验证命令是否可执行
- reviewer 必须按 `read_first:` 抽查 IMPLEMENT 是否真读了，按 `convergence:` 抽查每条 criterion 是否可执行

### CODE_REVIEW

- 实现是否满足计划
- 是否有明显漏做、做错、多做
- 最新 `Implementation Notes` 是否和代码一致
- 是否还需要回 IMPLEMENT 补证据或补实现

## TodoWrite Milestones

- 适用：`claudecode`；其余 backend 视宿主实现而定。
- TodoWrite 是 Claude Code 内置 surface，不引入新依赖。
- milestone 是事件，不是签到点；遇到 blocker、证据缺口或 scope 漂移时，必须立刻汇报。
- 推荐最小节奏固定为：`context-loaded` → `findings-collected` → `run-appended`。
- `run-appended` 完成后，必须与最终的 verdict callback / `team_send_message` / 用户回报配对，不能只停在 TodoWrite 更新。
- 最小示例：
  - `context-loaded`：已读完 `plan.md`、最新实现证据与目标代码
  - `findings-collected`：finding、残留风险与结论已收敛
  - `run-appended`：新的 `Plan Review` 或 `Code Review` run 已追加完成

## 判定规则

- `pass`：当前阶段可以推进
- `revise`：退回上一可写阶段重做
  - `PLAN_REVIEW -> PLAN`
  - `CODE_REVIEW -> IMPLEMENT`

## 评分依据

- 4-dim score 使用 `completeness` / `consistency` / `accuracy` / `depth`
- 评分定义、阈值口径和示例统一看 [../../docs/工作流/quality-rubric.md](../../docs/工作流/quality-rubric.md)
- `-Quality` 打开时，review run 的 score 字段必须与该 rubric 的阈值一致；不要在本文件重复发明第二套标准

写完最新 run 后，再按下一阶段选择执行 `.assistant\entry\advance-stage.ps1`；它会自动调用 validator。

推进规则：

- `PLAN_REVIEW -> IMPLEMENT` 或 `PLAN_REVIEW -> PLAN` 前，必须让用户指定下一阶段 `tool`
- `CODE_REVIEW -> TEST` 或 `CODE_REVIEW -> IMPLEMENT` 前，必须让用户指定下一阶段 `tool`
- 如使用 profile，推进时同步传 `-Profile <profile-name>` 和完整 `-Model <model-id>`；profile 的 backend 必须等于 `-Tool`
- 推进命令固定为 `.assistant\entry\advance-stage.ps1 -TaskId <task-id> -Tool <next-tool>`

## 不要做的事

- 不要写独立 `review.md`
- 不要修改旧 run
- 不要省略 `verdict`

## Reference

- 写作规范: [../orchestrator/references/lite-writing-guide.md](../orchestrator/references/lite-writing-guide.md)
