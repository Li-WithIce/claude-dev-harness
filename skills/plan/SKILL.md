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
- frontmatter 必须包含：`task_id`、`stage`、`tool`、`updated`；可选 `tool_profile` / `model` 只能放在 `tool` 与 `updated` 之间
- `stage` 在 PLAN 内保持 `PLAN`；不要手改到下一阶段，推进只走 `.assistant\entry\advance-stage.ps1`
- 新任务进入 PLAN 前，未显式指定时默认使用 `tool: codex` + `harness-default-codex`
- PLAN 阶段的 `tool` 只允许：`claudecode`、`codex`
- 如使用 `tool_profile`，必须来自 `agent-configs/profiles/<name>.yaml`，且 profile `backend` 必须等于 `tool`
- 如写 `model`，必须使用完整模型 ID，不写 `opus`、`pro`、`latest` 这类短别名
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

### Clarification 协议族

当用户要求需求澄清、需求确认、拷问需求、拷问方案、头脑风暴、方案压力测试、设计访谈、边界确认、验收标准确认或非目标确认时，仍只在 `PLAN` 阶段处理，不新增 stage。

写作规则：

- 一次只推进一个关键问题；不要一次抛出多组互相交织的问题。
- 能通过读取代码库、文档或当前 task artifact 回答的问题，先自行查证，再写结论。
- 每个仍需用户决策的问题都要给出 `recommended_answer`，并说明推荐理由或取舍。
- 决策未确认前，`## User Confirmation` 保持 `- status: draft`；用户确认后再改为 `confirmed` 并推进。
- 推荐在 `## Clarification` 中用普通 bullets 记录 `question`、`recommended_answer`、`decision`、`dependencies`、`non_goals`；这些只是写作字段，不写入 frontmatter，也不被 `advance-stage.ps1` 或 validator 当作新 truth。

### work_type 路由

新建或重写 PLAN 时，建议在 `## Clarification` 内增加一行机器可读的工作类型分诊信号：

```markdown
- work_type: feature | bug | refactor | explore | doc | maintenance
```

`work_type` 描述本轮工作的意图和审查重点，只作为 PLAN / PLAN_REVIEW 的语义路由；不要写进 frontmatter，不要让 `advance-stage.ps1` 消费它，也不要把它作为第二套阶段真相源。

`work_type` 与 `Change Contract.change_type` 职责不同：

- `work_type`: 描述“为什么做 / 按哪类任务审”，例如修错、探索、文档维护。
- `change_type`: 描述“产物或变更类型”，继续使用现有 `task | feature | enhance | refactor` 枚举和 validator 规则。

旧任务没有 `work_type` 不视为缺陷；只有当当前计划主动启用该字段时，PLAN_REVIEW 才需要核对它是否与验收标准、非目标和验证命令一致。

### bug / refactor 条件化模板

以下模板只在 `work_type: bug` 或 `work_type: refactor` 时启用。不要为普通 feature/doc/maintenance 任务强制补这些字段，也不要新建 `bug-report.md`、`refactor-design.md` 或 analyze/fix 双阶段流程。

`work_type: bug` 的 PLAN 至少要让 IMPLEMENT 和 TEST 看清：

```markdown
- bug.repro: 可重复执行的复现步骤；无法稳定复现时写已知触发条件和缺口
- bug.expected: 期望行为
- bug.actual: 实际行为
- bug.impact: 影响范围和严重程度
- bug.root_cause_action: 根因定位动作；未知根因时写要先验证的假设
- bug.fix_verification: 修复后必须执行的验证动作
```

`work_type: refactor` 的 PLAN 至少要让 IMPLEMENT 和 TEST 看清：

```markdown
- refactor.invariant: 必须保持不变的外部行为
- refactor.scope: 本轮重构边界和明确不碰的模块
- refactor.callers: 受影响调用点或依赖面
- refactor.equivalence_check: 行为等价验证命令或手工检查
- refactor.rollback: 回滚路径或兼容性约束
- refactor.no_feature_change: 明确不引入功能行为变化
```

这些字段是现有 `## Clarification` / `## Verification` 的条件化补充，不是新的阶段状态。若某项确实不适用，写清理由，不要留空占位。

`## User Confirmation` 必须使用这条机器可读字段：

```markdown
## User Confirmation
- status: draft | confirmed
```

没有明确确认前写 `draft`；用户确认后改成 `confirmed`，然后再调用 `advance-stage.ps1`。

### 可选 Change Contract

`## Change Contract` 可在 `## User Confirmation` 与 `## Plan` 之间插入，用机器可读格式声明变更类型与受影响路径：

```markdown
## Change Contract
- change_type: task | feature | enhance | refactor
- affected_paths:
  - <path>
```

`change_type` 必须在枚举内；`affected_paths` 至少一条非占位条目。不需要时整段删除即可，validator 自动跳过。详见 `../orchestrator/references/lite-writing-guide.md`。

## 推荐骨架

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

## Change Contract
- change_type: task | feature | enhance | refactor
- affected_paths:
  - <path>

## Plan
- read_first: [docs/shared-memory-layers.md, scripts/validate-lite-artifacts.ps1]
- convergence:
  - `Select-String -Path scripts/validate-lite-artifacts.ps1 -Pattern '\[switch\]\$Quality'`
  - `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`
- artifacts: [docs/工作流/single-writer-precompact.md, scripts/validate-lite-artifacts.ps1]
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

Codex-only 默认 profile 写法如下；若显式切换 backend，必须换成匹配该 backend 的 profile/model：

```yaml
tool_profile: harness-default-codex
model: gpt-5.5/xhigh
```

`read_first:` / `convergence:` 都是 `## Plan` 段的可选 metadata-style 字段：

- 必须紧跟在 `## Plan` 标题之后，位于第一条普通 `- TODO ...` bullet 之前
- `read_first:` 必须使用 inline-array 语法
- `convergence:` 下面至少列 1 条可抽查的 criterion
- `artifacts:` 也是同一 metadata 块中的可选字段，示例顺序固定为 `read_first -> convergence -> artifacts`
- `artifacts:` 必须使用 inline-array 语法，且至少列 1 条任务产出路径
- 不需要时整段删除即可；不要把它们混到普通 TODO bullets 中

## 工作方式

1. 先读已批准输入和可选 `spec.md`
2. 把 Clarification 补齐到能执行的粒度
3. 写出精确文件路径、验证命令和风险
4. 用户确认后，把 `User Confirmation` 改成 `confirmed`
5. 推进到 `PLAN_REVIEW` 前，默认使用 workflow descriptor 的 `harness-default-codex`；如需切换 backend，再让用户指定下一阶段 `tool`
6. 只在 gate 满足后执行 `.assistant\entry\advance-stage.ps1 -TaskId <task-id>`；切换 backend 时追加 `-Tool <next-tool>`
7. 如需单独排查文档问题，再手动运行 `.assistant\entry\validate-lite-artifacts.ps1 -TaskId <task-id>`

## TodoWrite Milestones

- 适用：宿主提供 TodoWrite surface 时使用；不作为 Codex-only 默认流程的必需依赖。
- TodoWrite 是可选宿主 surface，不引入新依赖；没有该 surface 时用原生计划 / team board / 回报消息表达同等 milestone。
- milestone 是事件，不是签到点；遇到 blocker 时必须立刻汇报，不要堆积到收尾再说。
- 推荐最小节奏固定为：`phase-loaded` → `core-work-done` → `verification-done`。
- `verification-done` 之后必须紧跟最终的 stage callback / `team_send_message` / 用户回报，不能只停在 TodoWrite 完成。
- 最小示例：
  - `phase-loaded`：已读完 `plan.md` / `spec.md`，边界与验收已确认
  - `core-work-done`：`plan.md` 主体、受影响路径与验证命令已写完
  - `verification-done`：validator 与必要抽查已完成，准备进入下一步交接

## 不要做的事

- 不要写 `docs/<task-id>/...`
- 不要新建 `current-flow.md`、`review.md`、`implementation-notes.md`、`handoff.md`
- 不要覆盖历史 review / implementation runs

## Reference

- 写作规范: [../orchestrator/references/lite-writing-guide.md](../orchestrator/references/lite-writing-guide.md)
