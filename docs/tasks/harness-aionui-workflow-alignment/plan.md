---
task_id: harness-aionui-workflow-alignment
stage: PLAN
tool: claudecode
updated: 2026-04-24
---
# Harness 与 AionUi 工作流对齐优化

## Clarification
- 验收标准:
  - `D:\data\claude-dev-harness` 的工作流支持在任务启动阶段显式指定工具调用或 tool profile，而不是进入执行后再补判定
  - team 团队创建可由工作流节点预设或生成，便于与 `D:\data\AionUi-main` 的 team 模式对齐
  - skill 调用链路需要升级，使语义和入口更接近 AionUi 的 ACP 模式
  - 产出明确的改造边界、实现落点、迁移策略和验证思路，支撑后续实现与回归
- 非目标:
  - 不直接重写 `D:\data\AionUi-main` 主仓功能
  - 不处理与本次工作流对齐无关的 UI 重设计
  - 不无差别重写全部 skill，只改与 workflow / tool binding / ACP 对齐直接相关的部分
- 受影响目录:
  - `skills/`
  - `scripts/`
  - `.assistant/`
  - `docs/tasks/`
  - 具体实现落点待 architecture run 补齐
- 回滚策略:
  - 优先采用增量兼容改造，确保现有 harness 任务流程可以继续运行
  - 每条改造线都要保留独立回退点，避免一次性切断旧流程
- ui: not-applicable

## User Confirmation
- status: confirmed
- note: 用户已确认主改造仓库是 `D:\data\claude-dev-harness`，目标是让 harness 工作流与 `D:\data\AionUi-main` 更好结合

## Plan
- TODO 1: 梳理 `claude-dev-harness` 当前 workflow / orchestrator / team / skill 机制，并对照 `AionUi-main` 的 team / ACP 模式总结差距
- TODO 2: 明确“任务开始即指定工具”“workflow node 预设 team 创建”“ACP 化 skill 调用”三条改造线的设计边界
- TODO 3: 产出实现落点、风险、迁移策略和验证方案
- TODO 4: 基于架构结论拆分实现任务，并补充对应测试与验收路径

## Verification
- 首轮以架构差距分析、实现落点清单、现有测试基线盘点为准
- 进入实现后补充具体脚本、测试命令与回归范围

## Risks
- harness 当前 workflow 契约与 AionUi ACP / team 模式可能存在状态模型差异
- 任务起始即绑定工具，可能与现有 `stage/tool` 推进机制冲突
- team 预设与 skill 调用升级可能同时影响编排、提示词、artifact 契约和恢复逻辑

## Plan Review

## Implementation Notes

## Code Review
