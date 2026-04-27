# Phase 3 Code Review

## Findings

### P1 · `invoke-harness-skill.ps1` 没有按已发货 profile / install 根目录解析 user-level skills，导致真实环境下的 `codex` / `gemini` 代理分支可能找不到脚本

- `scripts/invoke-harness-skill.ps1:15` 声明了 `-ToolProfileId`，但仓库内没有任何后续消费；实际 skill 根目录解析完全不看 profile。
- `scripts/invoke-harness-skill.ps1:149-180` 的 `Resolve-ActiveSkillDirs` 只支持两级：workspace 下的 `.assistant\skills`，否则硬编码回落到 `%USERPROFILE%\.claude\skills`。
- 这和当前已发货的 profile 描述符不一致：`agent-configs/profiles/harness-default-codex.yaml:4-5` 声明的是 `.codex/skills`，`agent-configs/profiles/harness-default-gemini.yaml:4-5` 声明的是 `.gemini/skills`。
- 也和安装脚本的真实托管根不一致：`install.ps1:1119-1180` 只会把 repo `skills/` 同步到 Claude / Codex host roots（`$claudeSkillsPath` / `$codexSkillsPath`），并不会创建 workspace 级 `.assistant\skills`。
- 结果是，在常见的已安装布局里，只要 workspace 本身没有额外造一个 `.assistant\skills`，`codex` 分支 `scripts/invoke-harness-skill.ps1:446-461` 就会去找 `%USERPROFILE%\.claude\skills\codex\scripts\ask_codex.ps1`，而不是已安装的 Codex skills 根；`gemini-designer-main` 分支 `scripts/invoke-harness-skill.ps1:497-507` 也同样绕开了 profile 里声明的 `.gemini/skills`。
- 新增测试没有锁住这个真实路径契约，反而把错位路径固化进去了：`tests/verify-aionui-skill-contract.ps1:470` 只测 project-level `.assistant\skills` 的 Codex happy path，而 `tests/verify-aionui-skill-contract.ps1:499` 与 `tests/verify-aionui-skill-contract.ps1:528` 把 gemini / codex 的 user-level mock 都放在了 `.claude\skills`。所以当前 suite 全绿，不能证明 Phase 3 adapter 能在仓库自己安装出来的用户级目录上工作。

## Open Questions / Assumptions

- 假设：Phase 3 的 adapter user-level fallback 应该与已发货的 backend-specific profile / installer 根目录保持一致，而不是把所有 backend 都收敛到 `%USERPROFILE%\.claude\skills`。如果这里是有意重定义为单一路径，那至少 `agent-configs/profiles/*.yaml`、`skills/orchestrator/references/default-tool-profiles.md` 和安装层真相源都要同步改口，否则仓库现在存在明显的 truth-source 冲突。

## Change Summary

- `scripts/invoke-harness-skill.ps1` 的 ACP-style 基本外形已经落地：stdout 保持单行 JSON，诊断走 stderr，`review` / `test` stub、`implement` 拒绝、`codex` readonly 限制、已有 `### Run N` 内的 invocation trace 追加都已实现。
- `scripts/generate-skills-index.ps1` 与 `scripts/advance-stage.ps1` 的主要正向契约也已落地；本地回归里 `skill-manifest.json` 的 per-task best-effort 写入、workflow descriptor fallback/writeback、stdout/stderr 分离、validator advisory `Warnings:` 语义都通过。
- `verify-update-managed-assets.ps1` 已按 Leader 说明单独跟踪，本轮没有把它当默认 blocker。

## Evidence / Commands

- 代码与差异检查：
  - `git -C D:\data\claude-dev-harness status --short`
  - `git -C D:\data\claude-dev-harness diff -- scripts/invoke-harness-skill.ps1 scripts/generate-skills-index.ps1 scripts/advance-stage.ps1 tests/verify-aionui-skill-contract.ps1 tests/verify-skill-manifest.ps1 tests/verify-workflow-descriptor.ps1 tests/verify-tool-profile.ps1 tests/verify-workflow-contracts.ps1 tests/verify-lite-artifact-validator.ps1 tests/verify-lite-footprint.ps1 README.md skills/orchestrator/SKILL.md skills/orchestrator/references/runbook.md skills/orchestrator/references/default-tool-profiles.md skills/orchestrator/references/lite-writing-guide.md skills/orchestrator/references/state-templates.md`
  - `Get-Content` / `Select-String` 针对 `scripts/invoke-harness-skill.ps1`、`scripts/generate-skills-index.ps1`、`scripts/advance-stage.ps1`、`agent-configs/profiles/*.yaml`、`install.ps1`、`tests/verify-aionui-skill-contract.ps1`
- 实际运行：
  - `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-aionui-skill-contract.ps1`
  - `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-skill-manifest.ps1`
  - `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-descriptor.ps1`
  - `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-tool-profile.ps1`
  - `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-contracts.ps1`
  - `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-artifact-validator.ps1`
  - `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-footprint.ps1`

