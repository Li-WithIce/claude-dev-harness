---
name: implement
description: Use when the current workflow is in DEV and code must be implemented from the confirmed plan or fixed after review/test feedback.
---

# Implement - 代码实现技能

根据已确认的 `plan.md` 进行实现，或根据 `review.md` / `test.md` 的反馈回修。

## 核心原则

1. **严格遵循 plan**：实现以 `plan.md` 的 TODO 为准
2. **spec 可选**：只有当 `spec.md` 存在且被明确当作 delta-spec 使用时才读取
3. **最小变更**：只做 plan 要求的开发阶段改动
4. **TDD 铁律**：先写失败测试，再写最小实现，再验证通过
5. **handoff 必填**：每轮 DEV 都要刷新 `implementation-notes.md`
6. **尊重 tool_profile**：只在当前 stage binding 指向 DEV 时继续

## 前置条件

- `plan.md` 已存在且状态为 `已确认`
- `spec.md` 若存在，应作为开发边界补充而非完整需求主文档
- 如为回修轮次，可访问 `review.md` 或 `test.md`

## 工作流程

1. 阅读 `plan.md`，必要时读取 optional `spec.md`
2. 确认本轮要实现哪些 TODO
3. 按依赖顺序逐项实现
4. 每完成一个 TODO 就运行验证命令
5. 刷新 `docs/<task-id>/implementation-notes.md`
6. 把结果交回 `REVIEW(implementation)`

## implementation-notes.md 至少包含

- 改了什么
- 没改什么
- 风险点
- reviewer watchouts
- 本轮已执行的验证

## 关键约束

- 不跳过 plan 中的依赖顺序
- 不把开发阶段工作扩展成上游评审工作
- 不因为 `spec.md` 缺失就回退到全量需求流程
- 不在没有证据的情况下声称实现完成
