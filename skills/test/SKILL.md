---
name: test
description: Use when the current workflow is in TEST and the selected binding needs local validation, evidence collection, or a task-scoped `test.md` report.
---

# Test

面向当前开发阶段任务的本地测试协议。目标是验证实现是否满足 `plan.md` 和可选 delta-spec 的要求，并把结论写入 `docs/<task-id>/test.md`。

## 何时使用

- 当前 stage 是 `TEST`
- 需要生成或更新 `test.md`
- 需要为 HANDOFF 收集明确证据

不要用于修改业务实现或重写 `plan.md` / `spec.md`。

## 关键规则

- 严禁修改非测试业务代码
- 结论必须且只能是：`pass`、`fail`、`blocked`
- `pass` -> HANDOFF
- `fail` -> DEV
- `blocked` -> REVIEW(implementation) 或 DEV
- `spec.md` 是可选输入；存在时按 delta-spec 补充验证

## 推荐输入

- `docs/<task-id>/plan.md`
- optional `docs/<task-id>/spec.md`
- `docs/<task-id>/review.md`
- 当前代码改动和测试输出

## 执行流程

1. 读取 `plan.md`、optional `spec.md`、`review.md`
2. 提取验证点
3. 运行测试 / 手工验证
4. 保存原始证据
5. 逐项判定 `pass` / `fail` / `blocked`
6. 产出 `test.md`

## `test.md` 至少包含

- `# Test Report`
- `## Meta`
- `## Summary`
- `## Scope`
- `## Inputs Reviewed`
- `## Test Approach`
- `## Findings`
- `## Risks / Gaps`
- `## Conclusion`

## 关键约束

- 没有证据就不能写 `pass`
- 不把 `pass` 直接等价成 `DONE`
- TEST 的输出必须可被 `handoff.md` 直接消费
