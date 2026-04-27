# Phase 2 Code Review

## Findings

### P1 · `cli-profile` 失效时会被静默吞掉，并错误降级到 `workflow-default`

- `scripts/advance-stage.ps1:574-585` 在 `cli-profile` 分支里把 `Get-ToolProfile` 的任何异常都吞掉了。
- `scripts/advance-stage.ps1:588-598` 随后直接继续尝试 `workflow-default`。
- 这会让显式 CLI 输入不再 fail-closed。用户如果传了拼错的 `-Profile`，或者 profile 描述符缺 `backend/model`，脚本不会报 profile 错，而是可能继续按 descriptor 默认值推进到下一 stage。
- 这和本轮批准的“`cli-profile` 维持 Phase 1 兼容语义”不一致；显式参数被悄悄忽略，比直接报错更危险，因为会把任务推进到错误 runner 上。
- 现有测试没有覆盖这个负例。`tests/verify-workflow-descriptor.ps1:417-429` 只测了成功的 `cli-profile`，`tests/verify-workflow-descriptor.ps1:460-485` 只测了显式 `-Tool + -Profile` 的 mismatch rejection，没有“`-Tool` 为空、`-Profile` 无效/不存在”这条回归保护。

## Open Questions / Assumptions

- 假设：显式 CLI 输入应该保持权威语义并在无效时直接失败，而不是悄悄退到 `workflow-default`。如果这里有意允许“坏 `cli-profile` 自动降级”，那需要在 `plan.md`、README、runbook 和测试里明确写出来，因为这已经不是通常意义上的 Phase 1 兼容。

## Change Summary

- `scripts/advance-stage.ps1` 的主干路径基本按计划落地：`cli-tool`、`cli-profile`、`workflow-default` 三条分支都已实现；`workflow-default` 会把 descriptor 的 `default_profile/model` 写回下一 stage；当前 stage `tool_profile/model` 在 fallback 里保持 non-sticky；解析 trace 走 stderr，stdout 仍保持 `<stage> | <tool>`。
- `scripts/validate-lite-artifacts.ps1` 新增了 `Warnings:` 段和 workflow descriptor advisory audit，fatal failure 仍只由 `Failures` 决定，退出码语义保持 `Failures > 0 => exit 2`、否则 `exit 0`（`scripts/validate-lite-artifacts.ps1:1151-1192`）。
- `tests/verify-tool-profile.ps1:283-356` 仍保留了 profile descriptor 校验、tool/profile mismatch rejection、完整 model 校验和显式 profile 写回断言，并新增了 pure `cli-tool` clearing path；没有看到用放宽旧断言来掩盖其它回归的迹象。

## Evidence / Commands

- 代码与 diff：
  - `git status --short`
  - `git diff -- scripts/advance-stage.ps1 scripts/validate-lite-artifacts.ps1 tests/verify-workflow-contracts.ps1 tests/verify-lite-artifact-validator.ps1 tests/verify-lite-footprint.ps1 README.md skills/orchestrator/SKILL.md skills/orchestrator/references/default-tool-profiles.md skills/orchestrator/references/lite-writing-guide.md skills/orchestrator/references/runbook.md skills/orchestrator/references/state-templates.md vault-template/entry/advance-stage.ps1.template .gitignore`
  - `Select-String` / `Get-Content` 针对 `scripts/advance-stage.ps1`、`scripts/validate-lite-artifacts.ps1`、`tests/verify-workflow-descriptor.ps1`、`tests/verify-tool-profile.ps1`
- 实际运行：
  - `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-descriptor.ps1`
  - `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-tool-profile.ps1`
  - `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-contracts.ps1`
  - `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-artifact-validator.ps1`
