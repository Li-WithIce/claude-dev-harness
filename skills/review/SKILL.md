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
- findings:
  - P1: ...
  - P2: ...
- next: 下一步动作；无则写 none
```

`advance-stage.ps1` 只读取最新一条 run 的 `- verdict:`，所以字段名不要变。

## 审查重点

### PLAN_REVIEW

- Clarification 是否完整
- User Confirmation 是否已经 `confirmed`
- 计划粒度是否足够指导实现和验证
- 风险和验证命令是否可执行

### CODE_REVIEW

- 实现是否满足计划
- 是否有明显漏做、做错、多做
- 最新 `Implementation Notes` 是否和代码一致
- 是否还需要回 IMPLEMENT 补证据或补实现

## 判定规则

- `pass`：当前阶段可以推进
- `revise`：退回上一可写阶段重做
  - `PLAN_REVIEW -> PLAN`
  - `CODE_REVIEW -> IMPLEMENT`

写完最新 run 后，再按下一阶段选择执行 `.assistant\entry\advance-stage.ps1`；它会自动调用 validator。

推进规则：

- `PLAN_REVIEW -> IMPLEMENT` 或 `PLAN_REVIEW -> PLAN` 前，必须让用户指定下一阶段 `tool`
- `CODE_REVIEW -> TEST` 或 `CODE_REVIEW -> IMPLEMENT` 前，必须让用户指定下一阶段 `tool`
- 推进命令固定为 `.assistant\entry\advance-stage.ps1 -TaskId <task-id> -Tool <next-tool>`

## 不要做的事

- 不要写独立 `review.md`
- 不要修改旧 run
- 不要省略 `verdict`

## Reference

- 写作规范: [../orchestrator/references/lite-writing-guide.md](../orchestrator/references/lite-writing-guide.md)
