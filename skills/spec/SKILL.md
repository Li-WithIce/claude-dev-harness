---
name: spec
description: Use when PLAN 所需输入不足，必须补一个可选的 `docs/tasks/{task_id}/spec.md` 附件。
---

# Spec

`spec.md` 在 lite workflow 里只是 PLAN 的可选附件，不是独立 stage。

## 何时使用

- 当前任务需要额外边界说明才能写 `plan.md`
- 上游输入里缺接口、约束、验证差量
- orchestrator 明确判断当前还不能直接完成 PLAN

## 硬约束

- 固定路径：`docs/tasks/{task_id}/spec.md`
- 只补差量，不重写全量需求
- 不创建额外旧流程状态
- `plan.md` 仍然是唯一阶段真相源

## 推荐结构

如需支持跨任务关键词检索或长会话恢复时的快速命中，可在标题上方加入可选 frontmatter：

```yaml
---
front_keywords: [shared-memory, long-session, recovery]
---
```

```markdown
---
front_keywords: [shared-memory, long-session, recovery]
---
# <Task Title> Spec

## Gap
- 当前输入缺什么。

## Constraint
- 开发边界和兼容性约束。

## Verification Delta
- TEST 需要额外覆盖什么。
```

## 工作方式

1. 只写 PLAN 当前缺口
2. 写完后回到 `plan` skill 消费
3. 不手动推进 stage

## front_keywords 使用规则

- `front_keywords` 是 opt-in 字段，只在跨任务关键词检索或长会话恢复需要快速命中时使用。
- 单任务、无跨任务复用价值时不要写。
- 必须使用 inline-array 语法，优先使用 kebab-case。
- 单个 `spec.md` 最多写 5 个 keyword，避免关键词膨胀。

## Reference

- 写作规范: [../orchestrator/references/lite-writing-guide.md](../orchestrator/references/lite-writing-guide.md)
