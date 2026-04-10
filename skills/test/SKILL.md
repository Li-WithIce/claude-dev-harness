---
name: test
description: Use when the task is in TEST and you need to produce `docs/tasks/<task-id>/test.md` with a legal conclusion and handoff section.
---

# Test

TEST 的唯一产物是 `docs/tasks/<task-id>/test.md`。只有 `pass` 才能由 `advance-stage.ps1` 把任务推进到 `DONE`。

## 何时使用

- `plan.md` frontmatter 的 `stage` 是 `TEST`
- 需要生成或更新当前任务的 `test.md`
- 需要把验证结论和 handoff 摘要写成可推进格式

## 硬约束

- 不修改业务实现代码
- `## Conclusion` 下第一行必须且只能是：`pass`、`fail`、`blocked`
- `## Handoff` 必须存在
- `DONE` 由 `advance-stage.ps1` 写回 frontmatter，不在 `test.md` 里手写

## 最小模板

```markdown
# Test Report

## Summary
- 一句话结论摘要。

## Scope
- 本轮覆盖范围。

## Inputs Reviewed
- `docs/tasks/<task-id>/plan.md`
- `docs/tasks/<task-id>/spec.md`（如存在）

## Test Approach
- 实际执行的命令、手工检查或日志来源。

## Findings
- 关键发现；无则写 none。

## Risks / Gaps
- 残留风险或证据缺口；无则写 none。

## Conclusion
pass

## Handoff
- delivery: 交付摘要
- follow_up: 后续动作；无则写 none
```

## 工作流程

1. 读取 `plan.md` 和可选 `spec.md`
2. 收集真实测试证据
3. 按证据写 `test.md`
4. 确认 `Conclusion` 和 `Handoff` 合法
5. 只有结论为 `pass` 时再执行 `.assistant\entry\advance-stage.ps1 -TaskId <task-id>` 进入 `DONE`
6. `TEST -> DONE` 不需要再指定下一阶段 `tool`
7. 如需单独排查文档问题，再手动运行 `.assistant\entry\validate-lite-artifacts.ps1 -TaskId <task-id>`

## 不要做的事

- 没有证据时写 `pass`
- 省略 `## Handoff`
- 把 review 发现写成独立 `review.md`

## Reference

- 写作规范: [../orchestrator/references/lite-writing-guide.md](../orchestrator/references/lite-writing-guide.md)
