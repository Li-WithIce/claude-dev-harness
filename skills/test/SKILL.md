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
- artifact: 声明的 artifact 是否已经存在或交付；没有则说明原因
- drift: 是否发现 artifact / diff drift；没有则写 none
- follow_up_decision: 是否需要把未完成事项拆成新任务；没有则写 none
- memory_spec_update: 是否需要 memory / spec update；没有则写 none
- current_state: 当前阶段与关键产物路径   # optional
- key_decisions:                              # optional
  - decision: 跨会话必须保留的决策
    why: 决策原因
- next_actions:                               # optional
  - 恢复后第一组动作
```

`delivery` 与 `follow_up` 是 validator 最低必填；`artifact`、`drift`、`follow_up_decision`、`memory_spec_update` 是新任务的 finish boundary 写作要求，用来记录产物是否存在或已交付、是否存在 artifact / diff drift、follow-up 是否需要拆新任务、是否需要 memory / spec update。`current_state`、`key_decisions`、`next_actions` 为 opt-in 密度扩展，推荐长任务填写。旧格式 Handoff（只含 delivery/follow_up）继续通过 validator。格式契约以 `../orchestrator/references/lite-writing-guide.md` 为单一真相源。

若 `Plan.artifacts` 声明了 `docs/tasks/<task-id>/task-entity.yaml`，TEST/Handoff 需要在 `artifact` 或 `drift` 中说明该 Task entity advisory artifact 是否已交付，以及是否发现 stage/status/verdict/tool/current pointer 类 second truth 风险。TEST 不解析 task entity schema，也不把它当作阶段状态来源。

若 `Plan.artifacts` 声明了 `docs/tasks/<task-id>/context-manifest.yaml`，TEST/Handoff 需要在 `artifact` 或 `drift` 中说明该 Context Manifest advisory artifact 是否已交付，以及是否发现覆盖 `read_first:`、lazy loading、`skills_whitelist`、workflow descriptor 或自动注入的 second truth 风险。TEST 不解析 context manifest schema，也不把它当作加载或注入来源。

若 `Plan.artifacts` 声明了 `docs/tasks/<task-id>/case.md`，TEST/Handoff 需要在 `artifact` 或 `drift` 中说明该 Case Artifact advisory evidence bundle 是否已交付，是否覆盖复现、时间线、证据、命令、环境和 open gaps，以及是否发现替代 `test.md` 结论或 Handoff 的 second truth 风险。TEST 不解析 case schema，也不把它当作阶段状态来源。

## work_type 条件化验证

当 `plan.md` 的 `## Clarification` 含 `work_type: bug` 或 `work_type: refactor` 时，TEST 仍只产出同一个 `docs/tasks/<task-id>/test.md`，不要新增 issue/refactor 专用报告或额外阶段。

`work_type: bug` 的 `## Test Approach` / `## Findings` 应覆盖：

- 重跑或等价执行 PLAN 中声明的复现步骤
- 验证期望行为已恢复，且实际行为不再出现
- 执行 PLAN 中声明的修复验证动作
- 覆盖影响范围内的最小回归；无法覆盖时在 `## Risks / Gaps` 写明

`work_type: refactor` 的 `## Test Approach` / `## Findings` 应覆盖：

- 执行 PLAN 中声明的行为等价验证
- 抽查受影响调用点或依赖面
- 说明未发现功能行为变化；若存在有意行为变化，TEST 应判为 `fail` 或 `blocked`，让任务回到前置阶段重定计划
- 记录未覆盖的兼容性或回滚风险

## 工作流程

1. 读取 `plan.md` 和可选 `spec.md`
2. 收集真实测试证据
3. 按证据写 `test.md`
4. 若声明了 `task-entity.yaml`、`context-manifest.yaml` 或 `case.md`，抽查文件存在性和 advisory-only 边界，并把结论写入 Handoff
5. 确认 `Conclusion` 和 `Handoff` 合法
6. 只有结论为 `pass` 时再执行 `.assistant\entry\advance-stage.ps1 -TaskId <task-id>` 进入 `DONE`
7. `TEST -> DONE` 不需要再指定下一阶段 `tool`
8. `DONE` 会清除 `tool_profile` / `model`，因为终态固定为 `tool: none`
9. 如需单独排查文档问题，再手动运行 `.assistant\entry\validate-lite-artifacts.ps1 -TaskId <task-id>`

## 不要做的事

- 没有证据时写 `pass`
- 省略 `## Handoff`
- 把 review 发现写成独立 `review.md`

## Reference

- 写作规范: [../orchestrator/references/lite-writing-guide.md](../orchestrator/references/lite-writing-guide.md)
