# Lite Writing Guide

本指南约束 `harness-lite` 主线里的任务文档写法。目标只有一个：让 `docs/tasks/<task-id>/` 下的产物既能给人看，也能被脚本稳定读取。

## 适用范围

- `docs/tasks/<task-id>/plan.md`
- `docs/tasks/<task-id>/spec.md`
- `plan.md` 里的 append-only `Plan Review / Implementation Notes / Code Review`
- `docs/tasks/<task-id>/test.md`

## 通用原则

- 只写当前 task 的差量信息，不重写全量背景。
- 机器可读字段必须逐字匹配，不改 section 名、不改字段名。
- 所有路径都写仓库内真实路径，不写“相关文件”“某模块”这类模糊说法。
- 所有验证命令都写可执行命令，不写“自行测试”。
- 不适用时写 `none` 或 `not-applicable`，不要留空标题或占位段落。
- append-only 区块只追加新 run，不回写或改写旧 run。

## plan.md 契约

### Frontmatter

`plan.md` frontmatter 只允许这 4 个字段：

```yaml
---
task_id: <task-id>
stage: PLAN | PLAN_REVIEW | IMPLEMENT | CODE_REVIEW | TEST | DONE
tool: claudecode | codex | gemini | none
updated: YYYY-MM-DD
---
```

规则：

- 非 `DONE` 阶段时，`tool` 只能是 `claudecode`、`codex`、`gemini`
- `DONE` 只能写 `tool: none`
- `tool` 表示“当前 stage 由哪个工具继续”，不是固定 profile

### 必备 section

推荐顺序固定为：

1. `## Clarification`
2. `## User Confirmation`
3. `## Plan`
4. `## Verification`
5. `## Risks`
6. `## Plan Review`
7. `## Implementation Notes`
8. `## Code Review`

### Clarification 最低要求

`## Clarification` 必须逐项覆盖：

- 验收标准
- 非目标
- 受影响目录 / 模块
- 回滚策略或兼容性约束
- `ui: <expectation | not-applicable>`

### User Confirmation

`## User Confirmation` 只使用这条机器可读字段：

```markdown
## User Confirmation
- status: draft | confirmed
```

### Plan 内容要求

- 每一项都是可执行动作，不写抽象口号。
- 尽量带文件路径或模块名。
- 控制在实现可直接消费的粒度。

正确示例：

```markdown
## Plan
- 更新 `scripts/advance-stage.ps1`，统一当前任务指针写法。
- 更新 `skills/obsidian-memory/scripts/check-shared-memory.ps1`，移除 `docs/<task-id>` fallback。
```

错误示例：

```markdown
## Plan
- 优化流程一致性。
- 修一些共享记忆问题。
```

### Verification 内容要求

- 写真实命令。
- 只列本轮需要执行的验证。

正确示例：

```markdown
## Verification
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-workflow-contracts.ps1`
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/verify-lite-footprint.ps1`
```

## spec.md 契约

`spec.md` 只是 PLAN 的可选附件，不是独立 stage。

推荐结构：

```markdown
# <Task Title> Spec

## Gap
- 当前输入还缺什么。

## Constraint
- 本轮必须遵守的边界和兼容性约束。

## Verification Delta
- TEST 需要额外补哪些验证。
```

规则：

- 只补缺口，不复制 `plan.md` 已经明确的内容。
- 不创建额外状态文件，不写 stage。

## Append-Only Run 契约

### Run 标题格式

所有 append-only run 都使用：

```markdown
### Run <N> · YYYY-MM-DD HH:mm · runner: <Runner>
```

### Plan Review / Code Review

固定格式：

```markdown
### Run 1 · 2026-04-09 10:30 · runner: Codex
- verdict: pass | revise
- findings:
  - P1: ...
  - P2: ...
- next: 下一步动作；无则写 none
```

规则：

- `advance-stage.ps1` 只读取最新 run 的 `- verdict:`。
- 没有 findings 时写 `- findings: none`，不要写空 severity 标题。
- 只在真的有问题时使用 `P0/P1/P2/P3`。

### Implementation Notes

推荐格式：

```markdown
### Run 1 · 2026-04-09 11:00 · runner: Codex
- changed: 更新了哪些文件或行为
- tests: 跑了哪些验证；无则写 none
- risks: 本轮残留风险；无则写 none
- next: 交给 CODE_REVIEW 关注什么；无则写 none
```

规则：

- 回修后必须追加新 run，不能复用旧 run 充当“新证据”。
- `changed` 写结果，不写空话。
- `IMPLEMENT` 若是接 `CODE_REVIEW revise` 回来，最新 run 必须比那条 review 更晚。

## test.md 契约

推荐结构：

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

规则：

- `## Conclusion` 下第一行必须且只能是 `pass`、`fail`、`blocked`。
- `## Handoff` 必须存在。
- 不要把 review 发现写成独立 `review.md`。

## 严重级别

推荐统一使用：

- `P0`: 阻塞继续推进
- `P1`: 高优先级缺陷或回归
- `P2`: 重要但不阻塞的偏差
- `P3`: 次要问题或文档修正

规则：

- 一个 finding 只标一个级别。
- 级别只用于真实 finding，不用于空标题占位。

## 自检清单

- [ ] 路径全部位于 `docs/tasks/<task-id>/`
- [ ] `plan.md` frontmatter 只有 4 个合法字段
- [ ] `tool` 与当前 `stage` 组合合法
- [ ] `User Confirmation` 使用机器可读 `status`
- [ ] append-only run 没有改写旧历史
- [ ] review run 含 `verdict`
- [ ] test.md 含 `Conclusion` 和 `Handoff`
- [ ] 验证命令可直接执行
