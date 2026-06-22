# Case Artifact

`case.md` 是长 debug、incident、复杂 bug 调查任务的可选证据包。它只保存调查过程和原始证据，便于恢复和复核；不替代 `plan.md`、`test.md`，也不参与 stage 推进。

## When To Use

- `work_type: bug` 且复现、根因、影响面或修复证据较长。
- incident / debug 调查可用 `work_type: explore` 或 `work_type: maintenance` 表达，且需要保留时间线、命令输出、日志片段或环境信息。
- 简单修复、纯文档改动、单命令验证任务不需要创建 `case.md`。

## Path And Declaration

- 路径固定为 `docs/tasks/<task-id>/case.md`。
- 若创建，必须写入同任务 `plan.md` 的 `## Plan` 顶部 `artifacts:` inline array。
- `case.md` 可以与 `task-entity.yaml`、`context-manifest.yaml` 并存，但三者都只是 advisory artifact。
- 旧任务不需要回填。

## Advisory-Only Boundary

- `plan.md` frontmatter 仍是 stage/tool 的唯一真相源。
- `test.md` 仍是最终验证结论和 Handoff 的唯一交付报告。
- `case.md` 不驱动 `advance-stage.ps1`、runtime pointer、team board、workflow descriptor、skill manifest 或 validator hard gate。
- validator 只会通过 artifact drift advisory 提醒声明产物是否存在，不解析 `case.md` schema。

## Recommended Structure

```markdown
# Case Artifact

## Summary
- One-line incident/debug summary.

## Reproduction
- Steps, trigger, expected behavior, actual behavior.

## Timeline
- YYYY-MM-DD HH:mm: event, command, observation.

## Evidence
- Logs, excerpts, screenshots, links, or command outputs.

## Commands
- Commands that reproduced, diagnosed, or verified the case.

## Environment
- OS, shell, tool versions, config, data shape, fixtures.

## Resolution
- Fix summary or investigation conclusion.

## Open Gaps
- Remaining unknowns or follow-up candidates; `none` if closed.
```

## Forbidden Fields

Do not write fields that create a second task truth source:

- `stage`
- `status`
- `verdict`
- `tool`
- `current_phase`
- `next_action`
- `active_task`
- `current_pointer`
- `handoff_conclusion`
- `done`

## Review And Test Expectations

- PLAN_REVIEW checks whether the task really needs `case.md`, whether it is declared in `artifacts:`, and whether the plan keeps it advisory-only.
- CODE_REVIEW checks whether the file exists when declared, whether it contains evidence rather than a second task state, and whether it aligns with implementation evidence.
- TEST/Handoff records whether `case.md` was delivered, whether it covers reproduction/timeline/evidence/commands, and whether any open gaps need a follow-up task.
