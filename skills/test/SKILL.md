---
name: test
description: Use when the task is in TEST and you need to produce `docs/tasks/<task-id>/test.md` with a legal conclusion and handoff section.
---

# Test

TEST 的唯一产物是 `docs/tasks/<task-id>/test.md`。只有 `pass` 才能由 `advance-stage.ps1` 把任务推进到 `DONE`。

`test.md` 的完整结构（section 顺序、`## Handoff` 字段、finish boundary、opt-in 密度扩展）以 [`../orchestrator/references/lite-writing-guide.md`](../orchestrator/references/lite-writing-guide.md) 的 test.md 契约为**单一真相源**；本页只列 TEST 阶段的硬约束与差量。

## 何时使用

- `plan.md` frontmatter 的 `stage` 是 `TEST`
- 需要生成或更新当前任务的 `test.md`，把验证结论和 handoff 摘要写成可推进格式

## 硬约束

- 不修改业务实现代码
- `## Conclusion` 下第一行必须且只能是：`pass`、`fail`、`blocked`
- `## Handoff` 必须存在；validator 最低必填 `- delivery:` 和 `- follow_up:`（其余 finish boundary 字段见 guide）
- 没有证据不写 `pass`
- `DONE` 由 `advance-stage.ps1` 写回 frontmatter，不在 `test.md` 里手写

## work_type 条件化验证

当 `plan.md` 的 `## Clarification` 含 `work_type: bug` 或 `work_type: refactor` 时，TEST 仍只产出同一个 `test.md`，不要新增 issue/refactor 专用报告或额外阶段。

`work_type: bug` 的 `## Test Approach` / `## Findings` 应覆盖：

- 重跑或等价执行 PLAN 中声明的复现步骤
- 验证期望行为已恢复、实际行为不再出现
- 执行 PLAN 中声明的修复验证动作
- 覆盖影响范围内的最小回归；无法覆盖时在 `## Risks / Gaps` 写明

`work_type: refactor` 的 `## Test Approach` / `## Findings` 应覆盖：

- 执行 PLAN 中声明的行为等价验证，抽查受影响调用点或依赖面
- 说明未发现功能行为变化；若存在有意行为变化，TEST 判为 `fail` 或 `blocked`，让任务回到前置阶段重定计划
- 记录未覆盖的兼容性或回滚风险

## 工作流程

1. 读取 `plan.md` 和可选 `spec.md`
2. 收集真实测试证据
3. 按证据和 guide 的 test.md 契约写 `test.md`
4. 确认 `Conclusion` 和 `Handoff` 合法
5. 只有结论为 `pass` 时再执行 `.assistant\entry\advance-stage.ps1 -TaskId <task-id>` 进入 `DONE`（不需要再指定下一阶段 `tool`；`DONE` 会清除 `tool_profile` / `model`）
6. 如需单独排查文档问题，再手动跑 `.assistant\entry\validate-lite-artifacts.ps1 -TaskId <task-id>`

## 不要做的事

- 没有证据时写 `pass`
- 省略 `## Handoff`
- 把 review 发现写成独立 `review.md`

## Reference

- 写作规范（单一真相源）: [../orchestrator/references/lite-writing-guide.md](../orchestrator/references/lite-writing-guide.md)
