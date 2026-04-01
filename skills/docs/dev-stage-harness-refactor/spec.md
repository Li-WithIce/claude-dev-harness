# 开发阶段 Harness 化工作流改造 需求规格说明

> 状态：已确认
> review_status：已收敛
> task_id: dev-stage-harness-refactor
> task_name: 开发阶段 Harness 化工作流改造
> 创建日期：2026-03-31
> 所属里程碑：开发流程改造

## 1. 概述

### 1.1 功能简述
将当前偏“全流程开发管理”的 skill 工作流，收敛为只服务开发阶段的执行 harness。新流程默认消费已完成的需求评审结果；若任务涉及用户可见 UI 变更，则一并消费已完成的 UI 评审结果；若存在技术方案评审结果，则作为增强输入一并消费。开发阶段不再重复承担这些上游评审职责，而是聚焦开发计划、实现、代码审查、测试和交付衔接。

### 1.2 所属模块
- 主稿源：`%USERPROFILE%\.claude\skills\`
- 镜像目标：`%USERPROFILE%\.codex\skills\`
- 任务文档目录：`%USERPROFILE%\.claude\skills\docs\`

### 1.3 关联文档
- `%USERPROFILE%\.claude\skills\using-superpowers\SKILL.md`
- `%USERPROFILE%\.claude\skills\orchestrator\SKILL.md`
- `%USERPROFILE%\.claude\skills\spec\SKILL.md`
- `%USERPROFILE%\.claude\skills\plan\SKILL.md`
- `%USERPROFILE%\.claude\skills\implement\SKILL.md`
- `%USERPROFILE%\.claude\skills\review\SKILL.md`
- `%USERPROFILE%\.claude\skills\test\SKILL.md`
- `%USERPROFILE%\.claude\skills\orchestrator\references\artifact-contracts.md`
- `%USERPROFILE%\.claude\skills\orchestrator\references\gates.md`
- `%USERPROFILE%\.claude\skills\orchestrator\references\runbook.md`
- `%USERPROFILE%\.claude\skills\orchestrator\references\state-templates.md`
- `%USERPROFILE%\.claude\skills\orchestrator\references\validation-scenarios.md`

### 1.4 当前现状与受影响模块
- 当前 workflow 以 `using-superpowers -> orchestrator -> spec -> plan -> implement -> review -> test` 为骨架，逻辑上接近“从需求到测试”的开发主流程。
- 你的真实使用边界更窄：需求评审通常已经在上游完成；UI 相关任务往往也已有 UI 评审，非 UI 任务则可显式标记 `not-applicable`；技术方案评审有时存在、有时不存在；你作为开发人员，只在开发阶段使用这套流程。
- 因此当前 `spec/plan` 的语义过重，容易把“上游审批文档”和“开发阶段执行文档”混在一起。
- 这次改造将主要影响入口路由、stage machine、artifact contract、各 stage skill 的职责定义，以及 `.claude` / `.codex` 双目录的一致性策略。

## 2. 用户故事与场景

### 2.1 目标用户
- 已拿到上游评审结论、需要进入开发执行阶段的开发人员。
- 维护这套 skill workflow 的开发工具链维护者。

### 2.2 用户故事
- 作为开发人员，我希望 workflow 直接消费“已评审通过”的需求、UI 输入，并在存在时消费技术方案评审结果，而不是把技术评审变成所有开发任务的默认硬前置。
- 作为开发人员，我希望 workflow 聚焦开发计划、实现、review、test 和交付，让每次推进都更像可验证的 harness，而不是自由对话。
- 作为 workflow 维护者，我希望 `.claude` 与 `.codex` 对同一套 stage、artifact 和 gate 有一致理解，避免双份规则漂移。

### 2.3 使用场景

**场景一：标准开发执行**
- 前置条件：需求评审已通过，并有可引用输入；若任务涉及用户可见 UI 变更，则 UI 评审也应已通过；技术方案评审结果如存在则一并可引用
- 期望结果：workflow 从“已批准输入”进入开发执行阶段，先形成开发计划，再实现、review、test，最后产出交付 handoff

**场景二：输入不完整的开发任务**
- 前置条件：需求/UI 输入已具备，但技术方案评审可能不存在，或给开发的输入仍存在缺口
- 期望结果：workflow 允许生成一个轻量 `delta-spec` 或“开发边界说明”，只补开发执行所需差量信息，而不是回退成全量需求流程

**场景三：测试失败回修**
- 前置条件：开发实现完成，`test.md` 给出 `fail`
- 期望结果：workflow 稳定 loop back 到 DEV，修复后重新 review/test，不跳阶段

## 3. 功能需求

### 3.1 输入
- 上游已批准输入：需求评审结论；若任务涉及用户可见 UI 变更，则还包括 UI 评审结论
- 可选增强输入：技术方案评审结论（若存在则消费；若不存在，不阻塞进入开发阶段 harness）
- 开发任务上下文：变更目标、影响模块、约束、回归范围
- 当前 skill workflow 文档与 orchestrator references

### 3.2 输出
1. 一套面向开发阶段的 workflow 定义，明确哪些上游输入被消费、哪些阶段由本流程负责
2. 更新后的 stage machine、artifact contract、gate 定义和 state 模板
3. 收敛后的 stage skill 职责定义
4. 开发阶段结束时的交付制品定义，用于交给验收/上线等下游角色
5. `.claude` 与 `.codex` 的一致镜像结果

### 3.3 核心行为描述

#### 3.3.1 流程定位
- 当前 skill workflow 的职责收敛为“开发阶段执行 harness”，而不是覆盖整个传统研发生命周期
- 需求评审作为默认输入；UI 评审仅在涉及用户可见 UI 变更时作为必需输入，否则显式标记 `not-applicable`；技术方案评审作为可选增强输入；三者都不作为本流程内的主要 stage
- 验收和上线不由本流程直接执行，只通过开发交付 handoff 与下游衔接

#### 3.3.2 入口行为
- `using-superpowers` 识别到开发任务时，仍然优先导向 `orchestrator`
- 但 `orchestrator` 启动的新流程默认以“已批准输入”为起点：最低要求是需求评审输入；若任务涉及用户可见 UI 变更，则还需要 UI 评审输入；技术方案评审若存在则直接消费，若不存在则由 `PLAN` 或 `DELTA_SPEC` 补齐开发边界，而不是默认要求重新形成全量需求 spec

#### 3.3.3 stage machine 行为
- 默认开发阶段流程应收敛为：`INTAKE -> PLAN -> DEV -> REVIEW(implementation) -> TEST -> HANDOFF`
- 当“已批准输入”不足以支撑开发执行时，允许插入可选的 `DELTA_SPEC` 制品或分支条件，用于补齐开发边界和差量约束；第一轮不把它做成默认独立 stage
- `fail` 必须可靠 loop back 到 DEV；`blocked` 必须形成阻断态；通过 TEST 后进入 HANDOFF
- 新写入统一使用 `HANDOFF` 语义；读取层允许对历史 `DONE` 保留一轮兼容别名，避免在途任务恢复链被立即打断

#### 3.3.4 artifact 行为
- `plan.md` 成为开发阶段的主文档
- `spec.md` 的语义收敛为“可选 delta-spec / 开发边界说明”，不再默认承担完整需求评审文档角色
- 第一轮继续复用现有 `handoff.md` 作为开发交付 artifact，用于把实现结果、测试结论、风险和下游注意事项交给下游角色
- 第一轮不新增 `delivery.md`，待主路径稳定后再决定是否需要独立交付制品

#### 3.3.5 harness 行为
- stage transition 必须由可验证的 gate 驱动，而不是靠 agent 自述
- state、artifact path、handoff、validation scenario 必须相互一致
- `.claude` 为主稿源，`.codex` 为镜像，不允许规则只改一边

### 3.4 业务规则与约束
- 当前真实业务流程常见为：需求评审 > UI评审 > 开发 > 测试 > 验收 > 上线；部分需求会在开发前增加技术方案评审
- 本次 skill workflow 只覆盖其中的“开发”子流程
- 上游评审是否完成，属于 workflow 输入前提，而不是本流程内部再审批一遍
- 技术方案评审不是默认硬前置：大多数需求可以在没有技术评审结论的情况下进入开发阶段 harness
- 若技术方案评审不存在，必须通过 `PLAN` 或可选 `DELTA_SPEC` 明确开发边界、关键约束与验证范围
- 第一轮收敛策略是“主路径先轻、分支后补”：默认 approved inputs 直接进入 `PLAN`
- 保留 `review` / `test` 的硬 gate 角色
- 保留 shared runtime / health gate 的硬门槛设计，但其语义应围绕“开发阶段当前任务”而不是全生命周期管理

## 4. 非功能需求

### 4.1 性能要求
- 核心 SKILL.md 正文继续保持可读，细则优先下沉到 `references/`
- 改造后不应显著增加维护者理解和执行成本

### 4.2 安全要求
- 不允许因为流程收敛而放松 review/test 的证据要求和阻断要求

### 4.3 兼容性要求
- 尽量复用现有 skill 名称与目录结构，降低迁移成本
- `.codex/skills` 镜像必须与 `.claude/skills` 的主稿语义一致，但镜像同步应发生在主稿收敛之后，不反向驱动主线决策
- 允许通过“语义收敛”而非“目录大改名”完成第一阶段改造

## 5. 边界与限制

### 5.1 明确包含（In Scope）
- 重新定义 workflow 在传统研发流程中的职责边界
- 重构开发阶段 stage machine 和 artifact 语义
- 收敛 `spec`、强化 `plan`、明确 `handoff`
- 更新各 stage skill、references 和 validation scenarios
- 同步 `.claude` / `.codex` 镜像策略

### 5.2 明确排除（Out of Scope）
- 不把需求评审、UI 评审、技术方案评审本身搬进 skill workflow 执行
- 不把验收和上线自动化进当前 workflow
- 不在本轮直接重做共享记忆体系的全部设计
- 不要求本轮直接实现完整 CI/CD 或外部审批系统

### 5.3 已知约束
- 当前 workflow 已经积累了不少以 `spec -> plan -> implement -> review -> test` 为前提的文档，需要兼顾迁移成本
- `.claude` / `.codex` 目前仍可能存在镜像漂移，改造计划必须显式处理
- 当前 shared runtime 仍有单写者约束，不能由所有 agent 任意改共享 pointer
- 当前第一优先级是先在 `.claude` 主稿内完成语义收敛，再统一同步 `.codex`

## 6. 验收标准（Acceptance Criteria）

### AC-1：流程定位收敛为开发阶段
- **Given** 改造完成
- **When** 阅读 using-superpowers、orchestrator 和 stage skill 文档
- **Then** 文档明确说明本 workflow 只覆盖开发阶段，不再假装承担完整研发生命周期

### AC-2：上游评审被建模为输入而非 stage
- **Given** 改造完成
- **When** 检查 stage machine、入口协议和 artifact contract
- **Then** 需求评审被视为默认 approved inputs；UI 评审仅在涉及用户可见 UI 变更时作为必需输入，否则显式标记 `not-applicable`；技术方案评审被视为可选增强输入，而非 workflow 内部必经 stage

### AC-3：开发阶段主流程清晰
- **Given** 改造完成
- **When** 检查 orchestrator stage map
- **Then** 默认主流程为 `INTAKE -> PLAN -> DEV -> REVIEW(implementation) -> TEST -> HANDOFF`，并允许可选 `DELTA_SPEC`

### AC-4：artifact 语义一致
- **Given** 改造完成
- **When** 检查 spec/plan/review/test 相关 contract 与模板
- **Then** `plan.md` 是开发主文档，`spec.md` 被收敛为可选 delta-spec，交付 handoff artifact 定义明确

### AC-5：gate 仍然硬约束
- **Given** 改造完成
- **When** 检查 gates、runbook、validation scenarios
- **Then** review/test 仍是硬门槛，`fail` / `blocked` 的 loop-back 或阻断语义不被削弱

### AC-6：双目录不再语义分叉
- **Given** 改造完成
- **When** 对比 `.claude` 与 `.codex` 中本次受影响文件
- **Then** 两边对同一套 stage、artifact 和 gate 的定义一致

## 7. 开放问题（Open Questions）

无。本轮与 `plan.md` 同步确认以下契约决策：

- `DELTA_SPEC` 第一轮按可选制品或分支条件处理，不作为默认独立 stage
- 开发交付第一轮继续复用 `handoff.md`
- 新写入统一使用 `HANDOFF`，读取层兼容 `DONE` 一轮
- 技术方案评审作为可选增强输入存在，不再作为默认硬前置

## 8. 变更记录

| 日期 | 变更内容 | 变更人 |
|------|---------|--------|
| 2026-03-31 | 创建首版 spec，明确“只在开发阶段使用”的改造背景与目标 | Codex |
| 2026-03-31 | 根据 plan-review 收敛 `DELTA_SPEC`、`handoff.md`、`HANDOFF/DONE` 的第一轮契约决策 | Codex |
| 2026-03-31 | 根据用户补充，降低技术方案评审作为默认前置的权重，改为可选增强输入 | Codex |
| 2026-03-31 | 进一步明确真实业务流中技术方案评审通常为可选环节，且 `.codex` 仅作为主稿收敛后的收尾镜像 | Codex |
