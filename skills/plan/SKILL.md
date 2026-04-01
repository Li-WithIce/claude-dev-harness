---
name: plan
description: Use when turning approved inputs and optional delta-spec into the main development execution document `plan.md`.
---

# Plan - 开发计划技能

`plan.md` 是开发阶段的主文档。它直接消费 approved inputs 和可选 delta-spec，产出开发执行、验证和交付 handoff 所需的核心信息。

## 核心原则

1. **plan 是主文档**：开发阶段以内，一切执行都以 `plan.md` 为准
2. **输入优先**：默认输入是已批准的需求评审和 UI 评审；技术方案评审是可选增强输入
3. **spec 可选**：只有存在 `DELTA_SPEC` 时才读取 `spec.md`
4. **执行友好**：TODO 必须粒度明确、路径精确、验证方式可执行
5. **handoff 前置**：计划中必须提前写出交付和下游 watchouts
6. **尊重 tool_profile**：若由 orchestrator 驱动，只在当前 stage binding 指向 PLAN 时继续

## 前置条件

- 已有 approved inputs
- 如有 `spec.md`，它只作为 delta-spec / 开发边界说明使用
- 如果 `current-flow.md` 存在，当前 stage 应为 `PLAN`

## 工作流程

1. 阅读 approved inputs、可选 `spec.md`、背景文档和现有代码结构
2. 提炼受影响目录、上下游依赖、接口影响和回归点
3. 把任务拆成可执行 TODO，明确依赖和并行关系
4. 写清每个 TODO 的验证命令、验收标准和 handoff 注意事项
5. 形成 `plan.md` 草稿
6. 用户确认后，将 `plan.md` 标为 `已确认`

## 建议模板

```markdown
# <功能名称> 实施计划

> task_id: <task-id>
> 关联 Spec：`docs/<task-id>/spec.md` | 无
> 创建日期：YYYY-MM-DD
> 状态：草稿 | 待确认 | 已确认
> review_status：未审查 | 需修订 | 已收敛

## 1. 技术方案概述

## 2. 技术决策

### 2.1 方案选型
### 2.2 第一轮轻量化与兼容约束
### 2.3 外部依赖
### 2.4 内部依赖
### 2.5 影响面地图

## 3. 任务拆解

- [ ] **TODO-xx**
  - **描述**：
  - **涉及模块**：
  - **精确文件路径**：
  - **依赖**：
  - **验收标准**：
  - **验证命令**：
  - **TDD 提醒**：
  - **Codex handoff**：

## 4. 依赖关系与执行顺序

### 4.1 依赖图
### 4.2 并行分组
### 4.3 关键路径

## 5. 测试标准

### 5.1 单元测试标准
### 5.2 集成 / 场景验证标准

## 6. 风险与缓解

## 7. 开放问题
```

## 关键约束

- 每个 TODO 必须有精确路径和验证方式
- `plan.md` 必须包含 handoff 所需信息
- 不把 `spec.md` 当成默认主文档
- 不因为轻量化而降低 review/test gate 强度
