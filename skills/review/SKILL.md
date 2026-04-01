---
name: review
description: Use when reviewing implementation output against the current plan and optional delta-spec during REVIEW(implementation).
---

# Review - 实现审查技能

本 skill 只用于 `REVIEW(implementation)`。它对照 `plan.md`、可选 `spec.md`、`implementation-notes.md` 和当前 diff，产出结构化 `review.md`。

## 核心原则

1. **plan 优先**：以 `plan.md` 为主审查依据
2. **spec 可选**：只有存在 delta-spec 时才把 `spec.md` 当作补充约束
3. **证据驱动**：结论必须基于代码与运行证据
4. **结构化输出**：固定输出到 `docs/<task-id>/review.md`
5. **P0/P1 阻塞 TEST**：只有仅剩 `P2` 时才能进入 TEST
6. **P2 必须传递**：所有 `P2` 风险都要进入 TEST / HANDOFF

## 输入

- `docs/<task-id>/plan.md`
- optional `docs/<task-id>/spec.md`
- `docs/<task-id>/implementation-notes.md`
- 当前 diff

## 审查维度

1. 功能完整性：是否满足 plan TODO 和验收标准
2. 逻辑正确性：是否有明显错误、漏做、做错
3. 架构合规性：是否遵循既有边界和依赖方向
4. 风险控制：是否引入明显安全 / 性能 / 回归风险
5. 证据质量：`implementation-notes.md` 与实际 diff 是否一致

## 输出模板

`review.md` 至少包含：

- `task_id` / `task_name`
- `review_scope: implementation`
- `review_verdict: pass | revise`
- Findings
- `P0 / P1 / P2`
- Summary
- Watchouts（传递到 TEST / HANDOFF）

推荐最小模板：

```markdown
# Review

> task_id: <task-id>
> task_name: <task-name>
> review_scope: implementation
> review_verdict: <pass|revise>
> reviewed_by: <tool>
> date: YYYY-MM-DD

## Findings

### P0

- 无

### P1

- 无

### P2

- 无

## Summary

用 1 段话概括实现是否满足 plan / delta-spec，并说明 verdict 的依据。

## Watchouts

- <需要传递到 TEST / HANDOFF 的风险或注意事项；若无写“无”>
```

- `review_verdict = pass` 仅当不存在 `P0 / P1` 时成立
- 只要存在 `P0 / P1`，`review_verdict` 必须写为 `revise`
- 仅剩 `P2` 时仍可写 `pass`，但所有 `P2` 都必须进入 `Watchouts`

## 关键约束

- 不负责 `spec.md` / `plan.md` 的文档 review
- 不把缺少证据的情况包装成通过
- 不遗漏 `P2` 风险传递
