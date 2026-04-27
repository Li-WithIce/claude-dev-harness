# Phase 3 Fix Review 2

## Findings

- no findings. `tests/verify-aionui-skill-contract.ps1` 现在已经把 `-ToolProfileId` 分支唯一锁住了：`Write-ToolProfileDescriptor` 会在 fixture repo 内动态生成一个测试专用 profile（`tests/verify-aionui-skill-contract.ps1:391-416`），`B2` 再把它的 `skills_dirs` 明确指到 backend 默认根之外的 `custom-hosts/gemini-profile-aware-skills`，并仅在该自定义目录下放置 gemini mock（`tests/verify-aionui-skill-contract.ps1:529-547`）。这意味着如果实现忽略 `-ToolProfileId`、只按 backend 默认 `.gemini\skills` 走，`B2` 会直接失败；它不再是之前那种与 backend 默认路径重合的伪 profile-aware 断言。新增的 `B3` 也形成了明确 negative control：沿用同一批 user fixture，但故意不传 `-ToolProfileId`，并断言 adapter 必须失败、stderr 指向 `.gemini\skills\gemini-designer-main\scripts\invoke-gemini.ps1`、且不会产生调用记录（`tests/verify-aionui-skill-contract.ps1:551-568`）。同时，文档口径也已同步为“project-level `.assistant/skills` 之后，user-level 读取 active profile/backend 对应的 `skills_dirs`”，且本轮没有把 install/uninstall 语义重新拉回本 Phase（`skills/orchestrator/references/default-tool-profiles.md:45-50`；`git diff -- install.ps1 uninstall.ps1` 为空）。

## Evidence / Commands

- 代码与 diff：
  - `git status --short`
  - `git diff -- tests/verify-aionui-skill-contract.ps1`
  - `Get-Content` / 带行号检查 `tests/verify-aionui-skill-contract.ps1:391-416, 529-568`
  - `Get-Content` / 带行号检查 `skills/orchestrator/references/default-tool-profiles.md:45-50`
  - `git diff -- install.ps1 uninstall.ps1`
- 实际运行：
  - `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-aionui-skill-contract.ps1`
  - `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-footprint.ps1`

## Conclusion

- scoped item resolved. 没有看到新的回归或残留测试缺口。
