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
- `task-entity.yaml` 只是可选 advisory artifact，路径为 `docs/tasks/<task-id>/task-entity.yaml`；不得写 stage/status/verdict/tool/current pointer 类字段
- `context-manifest.yaml` 只是可选 advisory artifact，路径为 `docs/tasks/<task-id>/context-manifest.yaml`；不得覆盖 lazy loading、`skills_whitelist`、workflow descriptor 或自动注入
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

### 可选 Task Entity Artifact

大型、跨分支、有父子任务或外部 issue/PR 关联的任务，可以在 PLAN 阶段创建 `docs/tasks/<task-id>/task-entity.yaml`。它只记录 owner、priority、branch、base_branch、pr_url、parent、children、related_files、external_refs、meta 和 notes 等任务元数据。

启用规则：

- 必须把 `docs/tasks/<task-id>/task-entity.yaml` 加入 `## Plan` 的 `artifacts:` inline array。
- 不要在 `task-entity.yaml` 写 `stage`、`status`、`verdict`、`tool`、`current_phase`、`next_action`、`active_task`、`current_pointer`、`handoff_conclusion` 或 `done`。
- 不要让它驱动 `advance-stage.ps1`、runtime mirror、team board、validator hard gate 或 skill manifest。
- 旧任务不需要回填；当前任务不需要时不要新建空文件。
- 发现 task entity 会制造 second truth 风险时，优先删减字段或回到 PLAN 调整边界。

### 可选 Subtask Roadmap Artifact

大型 roadmap、父子任务拆分或依赖较多的任务，可以在 PLAN 阶段声明 `docs/tasks/<task-id>/subtasks.yaml` 或 `docs/roadmaps/<slug>/items.yaml`。它只保存拆分项、依赖、完成判据、相关 artifact 和 open gaps，方便拆分、复核和恢复。

启用规则：

- 适用于 parent/child task、跨多个 `docs/tasks/<task-id>/` 的 roadmap，或需要清晰依赖关系的大型计划；不要为普通单任务创建空 roadmap。
- 必须把实际创建的 `docs/tasks/<task-id>/subtasks.yaml` 或 `docs/roadmaps/<slug>/items.yaml` 加入 `## Plan` 的 `artifacts:` inline array。
- 不要在 roadmap artifact 写 `stage`、`status`、`verdict`、`tool`、`current_phase`、`next_action`、`active_task`、`current_pointer`、`handoff_conclusion` 或 `done`。
- 不要让它驱动 `advance-stage.ps1`、runtime mirror、team board、queue/scheduler、validator hard gate、workflow descriptor、skill manifest、PR 自动化或 worktree 自动化。
- `task-entity.yaml` 记录单任务 metadata；subtask roadmap 记录拆分、依赖和完成判据。两者都不能替代 `plan.md` / `test.md`。
- 旧任务不需要回填；当前任务不需要时不要新建空文件。

### 可选 Context Manifest Artifact

多阶段、大量事实源、跨任务研究或后续恢复成本高的任务，可以在 PLAN 阶段创建 `docs/tasks/<task-id>/context-manifest.yaml`。它只记录 phase、file、reason、required 和 notes 等上下文读取建议。

启用规则：

- 必须把 `docs/tasks/<task-id>/context-manifest.yaml` 加入 `## Plan` 的 `artifacts:` inline array。
- 不要在 `context-manifest.yaml` 写 `stage`、`status`、`verdict`、`tool`、`current_phase`、`next_action`、`active_task`、`current_pointer`、`skills_whitelist`、`auto_inject`、`injector`、`load_by_default` 或 `workflow_state`。
- 不要让它驱动 `advance-stage.ps1`、runtime mirror、team board、validator hard gate、skill manifest、lazy loading、`skills_whitelist` 或 workflow descriptor。
- `read_first:` 仍是 Plan 顶部的最小入口清单；context manifest 只在复杂任务中补充阶段化原因说明。
- 旧任务不需要回填；当前任务不需要时不要新建空文件。
- 发现 context manifest 会制造 second truth 或自动注入风险时，优先删减字段或回到 PLAN 调整边界。

### 可选 Case Artifact

长 debug、incident 或复杂 bug 调查任务，可以在 PLAN 阶段声明 `docs/tasks/<task-id>/case.md`。它只保存复现、时间线、日志/命令证据、环境和调查结论，方便恢复和复核。

启用规则：

- 适用于 `work_type: bug`，或 incident/debug 类 `work_type: explore | maintenance` 任务；不要为普通小修创建空 `case.md`。
- 必须把 `docs/tasks/<task-id>/case.md` 加入 `## Plan` 的 `artifacts:` inline array。
- 不要在 `case.md` 写 `stage`、`status`、`verdict`、`tool`、`current_phase`、`next_action`、`active_task`、`current_pointer`、`handoff_conclusion` 或 `done`。
- 不要让它驱动 `advance-stage.ps1`、runtime mirror、team board、validator hard gate、workflow descriptor 或 skill manifest。
- `case.md` 不替代 `test.md`；最终验证结论和 Handoff 仍只写在 `test.md`。
- 旧任务不需要回填；当前任务不需要时不要新建空文件。

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
- 启用 Task entity 时，`artifacts:` 需要包含 `docs/tasks/<task-id>/task-entity.yaml`；它仍是 advisory 交付物，不是阶段状态
- 启用 Subtask Roadmap 时，`artifacts:` 需要包含实际创建的 `docs/tasks/<task-id>/subtasks.yaml` 或 `docs/roadmaps/<slug>/items.yaml`；它仍是 advisory 拆分清单，不是调度器或阶段状态
- 启用 Context Manifest 时，`artifacts:` 需要包含 `docs/tasks/<task-id>/context-manifest.yaml`；它仍是 advisory 交付物，不是加载或注入配置
- 启用 Case Artifact 时，`artifacts:` 需要包含 `docs/tasks/<task-id>/case.md`；它仍是 advisory 证据包，不是验证结论或阶段状态
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
