---
name: test
description: Use when the task is in TEST and you need to produce `docs/tasks/{task_id}/test.md` with a legal conclusion, evidence, and handoff section.
---

# Test

TEST 的唯一产物是 `docs/tasks/{task_id}/test.md`。`pass` 由 `advance-stage.ps1` 推进到 `DONE`，`fail` 返回 `IMPLEMENT`，`blocked` 保持 `TEST`。

`test.md` 的完整结构（section 顺序、`## Handoff` 字段、finish boundary、opt-in 密度扩展）以 [`../orchestrator/references/lite-writing-guide.md`](../orchestrator/references/lite-writing-guide.md) 的 test.md 契约为**单一真相源**；本页只列 TEST 阶段的硬约束与差量。

## 何时使用

- `plan.md` frontmatter 的 `stage` 是 `TEST`
- 需要生成或更新当前任务的 `test.md`，把验证结论和 handoff 摘要写成可推进格式

## 硬约束

- 不修改业务实现代码
- `## Conclusion` 下第一行必须且只能是：`pass`、`fail`、`blocked`
- `## Evidence` 必须记录 `command`、`exit_code`、`executed_at`、`revision`、`evidence_path`
- `## Handoff` 必须存在；validator 最低必填 `- delivery:` 和 `- follow_up:`（其余 finish boundary 字段见 guide）
- 没有证据不写 `pass`
- `fail` 表示验证已否证当前实现、可返回实现修复；无法完成验证或等待外部条件时写 `blocked`，不要用它触发返修
- 按阶段原则路由，TEST 用 Bayes 视角：用真实验证更新结论，无法验证的项写入风险或缺口
- `DONE` 由 `advance-stage.ps1` 写回 frontmatter，不在 `test.md` 里手写；它只表示结构化 TEST attestation 已通过，不等于计划中的任意命令已被 stage driver 执行

## Stage Discipline

Use the TEST and Handoff/DONE disciplines from `docs/工作流/stage-discipline-matrix.md` when the task needs stage-discipline clarification or stage-behavior review:

- Treat PLAN and IMPLEMENT as hypotheses.
- Use real commands, outputs, inspections, or documented constraints as evidence.
- Do not claim `pass` without evidence.
- Make Handoff clear enough for a future maintainer.

## work_type 条件化验证

当 `plan.md` 的 `## Clarification` 含 `work_type: bug` 或 `work_type: refactor` 时，TEST 仍只产出同一个 `test.md`，不要新增 issue/refactor 专用报告或额外阶段。

`work_type: bug` 的 `## Test Approach` / `## Findings` 应覆盖：

- 重跑或等价执行 PLAN 中声明的复现步骤
- 验证期望行为已恢复、实际行为不再出现
- 执行 PLAN 中声明的修复验证动作
- 覆盖影响范围内的最小回归；无法覆盖时在 `## Risks / Gaps` 写明

`work_type: refactor` 的 `## Test Approach` / `## Findings` 应覆盖：

- 执行 PLAN 中声明的行为等价验证，抽查受影响调用点或依赖面
- 说明未发现功能行为变化；若验证否证当前实现则写 `fail` 返回 IMPLEMENT；若因外部条件无法完成则写 `blocked` 留在 TEST
- 记录未覆盖的兼容性或回滚风险

## 工作流程

1. 读取 `plan.md` 和可选 `spec.md`
2. 收集真实测试证据
3. 按证据和 guide 的 test.md 契约写 `test.md`
4. 确认 `Conclusion`、`Evidence` 和 `Handoff` 合法
5. 结论为 `pass` 或 `fail` 时执行同一 `.assistant\entry\advance-stage.ps1 -TaskId {task_id} -ExpectedStage TEST`：pass 进入 `DONE`，fail 进入 `IMPLEMENT`；均无需新增 reopen 参数，非 DONE tool 由 workflow descriptor 解析
6. `blocked` 不调用推进命令；保留 TEST 并在 Handoff / Risks 写清解除条件
7. 如需单独排查文档问题，再手动跑 `.assistant\entry\validate-lite-artifacts.ps1 -TaskId {task_id}`

## 不要做的事

- 没有证据时写 `pass`
- 省略 `## Evidence` 或 `## Handoff`
- 把 review 发现写成独立 `review.md`

## Reference

- 写作规范（单一真相源）: [../orchestrator/references/lite-writing-guide.md](../orchestrator/references/lite-writing-guide.md)
