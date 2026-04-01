---
name: spec
description: Use when approved inputs are insufficient and the development harness needs an optional delta-spec to clarify implementation boundaries.
---

# Spec - delta-spec 技能

本 skill 不再承担“完整需求规格说明”职责。它只在开发阶段输入不足时产出 `docs/<task-id>/spec.md`，用于补齐开发边界、关键约束和验证差量。

## 核心原则

1. **默认不启用**：只有 approved inputs 不足时才进入本 skill
2. **只补差量，不重写全量需求**：`spec.md` 只写当前开发所需的增量边界
3. **服务 PLAN，不自成主线**：`spec.md` 的目标是让 `PLAN` 能继续推进
4. **固定产出**：输出到 `docs/<task-id>/spec.md`
5. **尊重 tool_profile**：若由 orchestrator 驱动，只在 `INTAKE` 明确要求 `DELTA_SPEC` 时继续

## 触发条件

满足以下任一条件时使用：

- 已有需求评审 / UI 评审，但仍缺少开发边界、关键约束、回归范围
- 技术方案评审不存在，且当前输入不足以直接形成开发计划
- orchestrator 在 `current-flow.md` 中将 `delta_spec.required` 标为 `true`

以下情况不要用本 skill：

- 只是因为没有技术方案评审文档
- 想重新做完整需求评审
- 想替代 `plan.md` 作为开发主文档

## 前置条件

- `current-flow.md` 已记录 approved inputs
- 缺口原因已经明确
- 如果 `current-flow.md` 存在，当前 stage 应为 `INTAKE`，或 handoff 明确要求补写 delta-spec

## 工作流程

1. 阅读 approved inputs、背景文档和现有代码上下文
2. 明确当前输入为什么不足以进入 PLAN
3. 只补以下内容：
   - 开发边界
   - 关键约束
   - 未明确的接口或数据契约
   - 需要额外验证的差量范围
4. 产出或修订 `docs/<task-id>/spec.md`
5. 将 `spec.md` 状态更新为 `草稿`、`待确认` 或 `已确认`
6. 返回 orchestrator，由 `PLAN` 继续消费

## 建议模板

```markdown
# <功能名称> Delta Spec

> task_id: <task-id>
> task_name: <task-name>
> 状态：草稿 | 待确认 | 已确认
> review_status：未审查 | 需修订 | 已收敛

## 1. 输入缺口

说明为什么已批准输入仍不足以进入 PLAN。

## 2. 开发边界

只写当前开发需要补齐的边界，不重述完整需求。

## 3. 关键约束 / 假设

- <约束>
- <假设>

## 4. 验证差量

说明哪些验证点必须在 PLAN / TEST 中额外覆盖。

## 5. 风险 / 开放点

- <风险或未决点>
```

## 关键约束

- 不把 `spec.md` 写成完整 PRD
- 不默认要求用户再走一轮需求评审
- 只补 PLAN 所需最小信息
- 结论必须能被 `plan.md` 消费
