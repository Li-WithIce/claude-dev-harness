---
name: plan
description: Use when the task is in PLAN and you need to create or revise the authoritative `docs/tasks/<task-id>/plan.md`.
---

# Plan

PLAN 的唯一产物是 `docs/tasks/<task-id>/plan.md`，它的 frontmatter 是 lite workflow 的唯一阶段真相源。

完整写作契约以 [`../orchestrator/references/lite-writing-guide.md`](../orchestrator/references/lite-writing-guide.md) 为**单一真相源**：frontmatter 字段规则、`## Change Contract`、`## Plan` 顶部 `read_first / convergence / artifacts` 语法、`work_type: bug | refactor` 条件化模板、Clarification 协议族和阶段原则路由写法都在那里，本页不重复，只列 PLAN 阶段的 gate 与差量。

## 何时使用

- 当前 `plan.md` frontmatter 的 `stage` 是 `PLAN`
- 需要为新任务建首版 `plan.md`
- PLAN_REVIEW 退回后，需要重写计划并保留既有 review 历史

## PLAN gate（advance 前必须满足）

`plan.md` 至少按此顺序包含 section：`## Clarification` → `## User Confirmation` → `## Plan` → `## Verification` → `## Risks` → `## Plan Review` → `## Implementation Notes` → `## Code Review`。

`## Clarification` 必须逐项写清（与 `advance-stage.ps1` / validator 同一口径）：

- 验收标准
- 非目标
- 受影响目录 / 模块
- 回滚或兼容性约束
- `ui: <expectation | not-applicable>`

`clarification_ledger` 只补充问题树和决策留痕，不能替代上述最低字段；这些字段仍是 `advance-stage` / validator 的机器可读输入。

`## User Confirmation` 用机器可读 `- status: draft | confirmed`：用户确认前保持 `draft`；若存在 `clarification_ledger`，还必须没有 `decision: pending`，才可改 `confirmed` 并推进。

`## Plan` 至少 1 条可执行 TODO bullet；`## Verification` 至少 1 条 backtick 包住的可执行命令。

## 骨架

```markdown
---
task_id: <task-id>
stage: PLAN
tool: codex
tool_profile: harness-default-codex
model: gpt-5.5/xhigh
updated: 2026-04-09
---
# <Task Title>

## Clarification
- work_type: feature | bug | refactor | explore | doc | maintenance
- 验收标准: ...
- 非目标: ...
- 受影响目录: ...
- 回滚策略: ...
- ui: not-applicable

## User Confirmation
- status: draft

## Plan
- read_first: [docs/shared-memory-layers.md, scripts/validate-lite-artifacts.ps1]
- TODO 1: ...

## Verification
- `pwsh -File tests/...`

## Risks
- ...

## Plan Review

## Implementation Notes

## Code Review
```

可选 `## Change Contract`（插在 User Confirmation 与 Plan 之间）、`## Plan` 顶部 `convergence: / artifacts:`、`work_type` 的 bug/refactor 模板等字段格式，全部见 guide。

## work_type（可选语义路由）

可在 `## Clarification` 加一行 `- work_type: feature | bug | refactor | explore | doc | maintenance`，只作为 PLAN / PLAN_REVIEW 的审查路线，不写入 frontmatter、不被 `advance-stage.ps1` 消费、不是第二真相源；与 `Change Contract.change_type`（产物/变更类型枚举）职责不同。

## Clarification 协议族

当用户要求需求澄清 / 拷问 / 头脑风暴 / 方案压力测试 / 边界确认等同族请求，或 PLAN 的验收、非目标、影响面、回滚/兼容仍不确定，或实现路径仍不足以指导 IMPLEMENT 时，仍只在 `PLAN` 阶段处理，不新增 stage：先自查代码 / 文档 / artifact，在 `## Clarification` 写 `clarification_ledger`，同时保留 Clarification 最低字段，剩余用户决策按依赖顺序一次只问一个并给 `recommended_answer`；所有 `decision` 解除 `pending` 前，`## User Confirmation` 保持 `draft`。详细写法见 guide。

## 推理纪律（第一性原理 / 剃刀 / 贝叶斯）

解决问题、修 bug、设计架构或方案时，Clarification 与 Plan 的推理按三条纪律收敛：**第一性原理**回到根本约束与根因（bug 用 `bug.root_cause_action` 对齐根因，呼应“症状补丁”反射检查）、**剃刀法则**在满足验收前提下选最简方案并砍掉计划外抽象与顺手重构、**贝叶斯更新**随新证据（代码事实 / 验证结果 / review finding）修正结论（呼应 Clarification“一次一个关键问题、先自查再给 `recommended_answer`”）。只改推理与写作，不新增 stage / 字段 / gate。详见 guide 的“推理纪律”。

PLAN 阶段默认按 Osborn 打开发散空间、Hegel 收敛矛盾与依赖，再用 First Principles + Occam 选择最小必要方案；这只是写作视角，不新增五转流程。

## 工作方式

1. 先读已批准输入和可选 `spec.md`
2. 把 Clarification 补齐到能执行的粒度，写出精确文件路径、验证命令和风险；`clarification_ledger` 的非 `impact: none` 决策必须落到 Plan / Verification / Risks
3. 用户确认且 `clarification_ledger` 没有 `decision: pending` 后，把 `User Confirmation` 改成 `confirmed`
4. gate 满足后执行 `.assistant\entry\advance-stage.ps1 -TaskId <task-id>`（默认走 workflow descriptor 的 `harness-default-codex`，切换 backend 时追加 `-Tool <next-tool>`）
5. 如需单独排查文档问题，再手动跑 `.assistant\entry\validate-lite-artifacts.ps1 -TaskId <task-id>`

## 不要做的事

- 不要写 `docs/<task-id>/...`
- 不要新建 `current-flow.md`、`review.md`、`implementation-notes.md`、`handoff.md`
- 不要覆盖历史 review / implementation runs

## Reference

- 写作规范（单一真相源）: [../orchestrator/references/lite-writing-guide.md](../orchestrator/references/lite-writing-guide.md)
