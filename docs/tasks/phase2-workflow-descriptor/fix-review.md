# Phase 2 Fix Review

## Findings

- no findings. `scripts/advance-stage.ps1:574-583` 现在在显式 `cli-profile` 分支直接调用 `Get-ToolProfile`，解析失败会直接抛出，不再静默继续到 `workflow-default`；`scripts/advance-stage.ps1:585-595` 的 `workflow-default` 只在 `cli-tool` / `cli-profile` 都缺失时才会被尝试。`tests/verify-workflow-descriptor.ps1:431-447` 也新增了 B3 回归，用非零退出码、空 stdout、错误信息包含 `Missing tool profile descriptor:`、stderr 不含 `via workflow-default`、plan 仍停留在原 stage、且不生成 task mirror 来锁住 fail-closed 行为。与此同时，既有批准语义没有被带坏：valid `cli-profile` 仍由 B2 覆盖（`tests/verify-workflow-descriptor.ps1:417-429`），`workflow-default` 仍由 B4/F1/F2 覆盖（`tests/verify-workflow-descriptor.ps1:450-462`, `539-563`），explicit `tool/profile` mismatch rejection 仍由 C2 覆盖（`tests/verify-workflow-descriptor.ps1:495-504`），pure `cli-tool` clearing path 仍由 B1 和 `tests/verify-tool-profile.ps1:318-356` 覆盖。

## Evidence / Commands

- 代码与 diff：
  - `git status --short`
  - `git diff -- scripts/advance-stage.ps1 tests/verify-workflow-descriptor.ps1`
  - `Get-Content` / `Select-String` 检查 `scripts/advance-stage.ps1:553-605`, `719-739`
  - `Get-Content` 检查 `tests/verify-workflow-descriptor.ps1:417-510`
- 实际运行：
  - `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-descriptor.ps1`
  - `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-tool-profile.ps1`

## Conclusion

- scoped item resolved. 没有看到新的行为回归。
