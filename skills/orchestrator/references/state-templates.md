# State Templates

## plan.md frontmatter

```yaml
---
task_id: <task-id>
stage: PLAN | PLAN_REVIEW | IMPLEMENT | CODE_REVIEW | TEST | DONE
tool: claudecode | codex | gemini | none
updated: YYYY-MM-DD
---
```

## plan.md skeleton

```markdown
# <Task Title>

## Clarification
- 验收标准: ...
- 非目标: ...
- 受影响目录: ...
- 回滚策略: ...
- ui: not-applicable

## User Confirmation
- status: draft

## Plan
- TODO 1: ...

## Verification
- `pwsh -File tests/...`

## Risks
- ...

## Plan Review

## Implementation Notes

## Code Review
```

## append-only run block

```markdown
### Run 2 · 2026-04-09 11:00 · runner: Codex
- verdict: pass
- findings:
  - none
- next: none
```

`Plan Review` 和 `Code Review` 读取 `verdict`；`Implementation Notes` 记录 `changed/tests/risks/next`。

## spec.md skeleton

```markdown
# <Task Title> Spec

## Gap
- 当前输入缺什么。

## Constraint
- 开发边界。

## Verification Delta
- 需要额外验证什么。
```

## test.md skeleton

```markdown
# Test Report

## Summary
- ...

## Scope
- ...

## Inputs Reviewed
- `docs/tasks/<task-id>/plan.md`

## Test Approach
- ...

## Findings
- ...

## Risks / Gaps
- ...

## Conclusion
pass

## Handoff
- delivery: ...
- follow_up: none
```

## task mirror skeleton

```markdown
---
task_id: <task-id>
stage: <stage>
tool: <tool>
updated: YYYY-MM-DD
---
# Task Mirror

- pointer: docs/tasks/<task-id>/plan.md
- assigned_tool: <tool>
- latest_plan_review: <pass|revise|none>
- latest_code_review: <pass|revise|none>
```
