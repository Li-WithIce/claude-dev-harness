# Phase 3 Fix Review

## Findings

### P2 · 新增回归还没有把 `-ToolProfileId` 分支“唯一地”锁死，当前主要锁住的是 backend-aware fallback

- `scripts/invoke-harness-skill.ps1:149-309` 现在确实会先读 `-ToolProfileId` 对应 profile 的 `skills_dirs`，并在缺失时按 backend 回落到 `.claude\skills` / `.codex\skills` / `.gemini\skills`；`skills/orchestrator/references/default-tool-profiles.md:47-49` 也同步成了同一口径，且本轮没有把 install/uninstall 改造重新拉回本 Phase（`git diff -- install.ps1 uninstall.ps1` 为空）。
- 但 `tests/verify-aionui-skill-contract.ps1:502-516` 这条 “profile-aware gemini” 用例并不是可区分的 profile-aware 断言：它传了 `-ToolProfileId 'harness-default-gemini'`，同时把 mock 放在 `.gemini\skills`，而 `scripts/invoke-harness-skill.ps1:217-229` 的 backend 默认映射本来就会把 `gemini` 指到 `.gemini\skills`。也就是说，即使未来回归把 `Read-ToolProfileDescriptor` / `-ToolProfileId` 整段删掉，只保留 backend 映射，这个测试仍会通过。
- `tests/verify-aionui-skill-contract.ps1:556-567` 的 C2 只锁住了 codex 的 backend-aware user-level fallback；它没有覆盖“显式给了 `-ToolProfileId` 时，adapter 必须按 descriptor 的 `skills_dirs` 走”的可区分场景。
- 结论上，本次运行态修复看起来是到位的，但“测试补强是否锁住真实 profile-aware / backend-aware 行为”这一点还差最后一步。需要一个能与 backend 默认路径区分开的 fixture profile，或者等价的定向断言，才能真正防止未来把 `-ToolProfileId` 支路回退成纯 backend 映射。

## Evidence / Commands

- 代码与 diff：
  - `git status --short`
  - `git diff -- scripts/invoke-harness-skill.ps1 tests/verify-aionui-skill-contract.ps1 skills/orchestrator/references/default-tool-profiles.md install.ps1 uninstall.ps1`
  - `Get-Content` / 带行号检查 `scripts/invoke-harness-skill.ps1:149-309, 437-506`
  - `Get-Content` / 带行号检查 `tests/verify-aionui-skill-contract.ps1:218-230, 493-567`
  - `Get-Content` / 带行号检查 `skills/orchestrator/references/default-tool-profiles.md:45-50`
- 实际运行：
  - `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-aionui-skill-contract.ps1`
  - `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-footprint.ps1`

## Conclusion

- scoped item 部分收敛：运行态路径解析已从硬绑 `%USERPROFILE%\.claude\skills` 修正为 profile/backend-aware，且 install/uninstall 没有被重新带回本 Phase；剩余问题是回归测试还没有唯一锁住 `-ToolProfileId` 分支。
