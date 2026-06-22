# Test Report

## Summary
- `artifact drift` advisory 已能正确处理已声明的非 ASCII 路径，中文路径不再因 Git quotePath 转义而误报未声明变更。

## Scope
- 覆盖 `scripts/validate-lite-artifacts.ps1` 的 Git changed path 采集。
- 覆盖 `tests/verify-lite-artifact-validator.ps1` 的非 ASCII path 回归 fixture 与 live baseline。
- 覆盖当前任务 `plan.md` / `test.md` artifact 交付状态。

## Inputs Reviewed
- `docs/tasks/artifact-drift-path-normalization/plan.md`
- `scripts/validate-lite-artifacts.ps1`
- `tests/verify-lite-artifact-validator.ps1`
- `docs/tasks/artifact-drift-advisory/plan.md`

## Test Approach
- `Select-String -Path scripts/validate-lite-artifacts.ps1 -Pattern 'core.quotePath|artifact drift|Get-GitChangedPathsForAudit|Normalize-RepoRelativePath'`
- `Select-String -Path tests/verify-lite-artifact-validator.ps1 -Pattern 'non-ASCII|quotePath|unicode|工作流|changed path is not declared'`
- `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`
- `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId artifact-drift-path-normalization`
- `git diff --check`

## Findings
- validator Git 调用已显式使用 `core.quotePath=false`。
- 回归测试新增 `docs/工作流/unicode-drift.md` fixture，并通过 `non-ASCII declared changed path is not drift warning` 检查。
- warning-only 语义未改变：drift 分支仍使用既有 `Add-Warning`，测试脚本继续断言 warning 出现时 exit code 为 0。

## Risks / Gaps
- 未覆盖极旧 Git 或非 UTF-8 终端环境；当前仓库验证使用本机 Git 与 `pwsh`，真实 fixture 已覆盖 Windows 下中文路径。

## Conclusion
pass

## Handoff
- delivery: 已交付 artifact drift 非 ASCII 路径归一化修复、回归测试和本任务验证报告。
- follow_up: none
- artifact: `docs/tasks/artifact-drift-path-normalization/plan.md` 与 `docs/tasks/artifact-drift-path-normalization/test.md` 均已存在；本任务未声明额外 advisory artifact。
- drift: none；实际 diff 落在 Change Contract affected_paths 内，且声明 artifacts 已交付。
- follow_up_decision: none；不需要拆新任务。
- memory_spec_update: none；本任务不涉及共享记忆或 spec 更新。
- current_state: DONE 阶段，`plan.md` frontmatter 已由 `advance-stage.ps1` 推进到终态。
