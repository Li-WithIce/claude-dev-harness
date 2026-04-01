# Review Templates

Use these templates for optional document review outputs such as `spec-review.md` and `plan-review.md`.
They are still useful for high-risk document changes and migration tasks, but they are no longer part of the default development harness stage machine.

## spec-review.md

Output path: `docs/<task-id>/spec-review.md`

```markdown
# <功能名称> Spec Review

> task_id: <task-id>
> task_name: <task-name>
> review_scope: spec
> target: docs/<task-id>/spec.md
> reviewed_by: <selected runner tool>
> date: YYYY-MM-DD
> verdict: settled | revise

## Summary

用 1 段话概括当前 delta-spec 是否已经足够清晰、完整、可支撑进入 PLAN。

## Findings

### Blocking

- [S1] <问题标题>
  - 类型：输入缺口未闭合 | 约束缺失 | 边界不清 | 验证差量不足
  - 位置：`spec.md` 的章节或小节
  - 问题：具体缺口是什么
  - 为什么阻塞：为什么这会阻止进入 PLAN
  - 建议动作：直接修订 | 向用户澄清

### Non-blocking

- [S2] <问题标题>
  - 类型：表述改进 | 结构优化 | 术语统一
  - 位置：`spec.md` 的章节或小节
  - 建议：如何改得更清晰

## User Clarifications Needed

- [ ] <需要再次问用户的问题>

若无，写 `无`。

## Acceptable Direct Revisions

- <可以直接修正文案的点>

若无，写 `无`。

## Verdict Basis

- settled: 当前 delta-spec 已足够支撑开发计划
- revise: 仍有阻塞进入 PLAN 的输入或边界缺口
```

## plan-review.md

Output path: `docs/<task-id>/plan-review.md`

```markdown
# <功能名称> Plan Review

> task_id: <task-id>
> task_name: <task-name>
> review_scope: plan
> target: docs/<task-id>/plan.md
> reviewed_by: <selected runner tool>
> date: YYYY-MM-DD
> verdict: settled | revise

## Summary

用 1 段话概括当前 plan 是否已经足够可执行、可验证、可交给 DEV。

## Findings

### Blocking

- [P1] <问题标题>
  - 类型：依赖顺序错误 | TODO 粒度过大 | 验证缺失 | 路径不精确 | handoff 信息不足
  - 位置：`plan.md` 的章节或 TODO 编号
  - 问题：具体缺口是什么
  - 为什么阻塞：为什么这会阻止进入 DEV
  - 建议动作：直接修订 | 向用户澄清

### Non-blocking

- [P2] <问题标题>
  - 类型：表达优化 | 批次调整 | 风险说明增强
  - 位置：`plan.md` 的章节或 TODO 编号
  - 建议：如何改得更稳

## User Clarifications Needed

- [ ] <需要再次问用户的问题>

若无，写 `无`。

## Acceptable Direct Revisions

- <可以直接修订的 TODO、依赖、验证命令或 handoff 说明>

若无，写 `无`。

## Verdict Basis

- settled: TODO 粒度、依赖顺序、验证方式、handoff 上下文都足够明确，能够安全进入 DEV
- revise: 仍有任何阻塞开发执行的缺口
```

## Verdict Rule

- `settled`: 没有阻塞进入下一步的文档缺口，且当前文档已足够被执行方消费
- `revise`: 仍有任何阻塞性问题，或仍需关键用户澄清
