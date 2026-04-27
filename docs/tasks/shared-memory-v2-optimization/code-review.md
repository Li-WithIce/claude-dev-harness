# Shared Memory v2 Code Review

## Findings

### P1 · `advance-stage` 仍然把 `运行时/tasks/<task-id>.md` 写成不含 `entry_host` 的 legacy shape，主路径的 task-runtime 单写者合同没有真正闭合

- `scripts/advance-stage.ps1:1309-1326` 构造的 task mirror frontmatter 只有 `task_id / stage / tool / [tool_profile] / [model] / updated`，没有 `entry_host`。
- `scripts/advance-stage.ps1:1348-1350` 仍会在每次成功推进 stage 时把这份 mirror 写到 `.assistant/运行时/tasks/<task-id>.md`，所以写回阶梯的主路径继续产出 legacy task-runtime。
- 这不是“task-runtime 本来不在本轮范围内”。实现面文档明确把 `.assistant/运行时/tasks/<task-id>.md` 列为 `advance-stage.ps1` / `promote-runtime-inbox.ps1` / `repair-shared-memory.ps1` 共同写入的 live surface：`docs/tasks/shared-memory-v2-optimization/implementation-surface.md:30,121-122`。
- 覆盖也没有锁住这条主路径。`tests/verify-workflow-contracts.ps1:391-403` 只断言 mirror 的 `tool` / `assigned_tool` / pointer 文本；对比之下，另外两条 task-runtime writer 已经显式锁了 `entry_host`：`tests/verify-promote-runtime-inbox.ps1:202`、`tests/verify-repair-shared-memory.ps1:309,412`。
- 影响：本轮 review 关注的 “`advance-stage` / `promote-runtime-inbox` / `repair-shared-memory` 三条 task-runtime 路径都锁住 `entry_host`” 现在只闭合了后两条。任何先由 `advance-stage` 创建或刷新过的 `运行时/tasks/<task-id>.md`，仍然缺少 v2 单写者模型依赖的 writer-host 字段。

## Open Questions / Assumptions

- `scripts/check-shared-memory-layers.ps1 -VaultRoot .\.assistant -RepoRoot .` 对仓库自带 repo-local `.assistant` 的 FAIL，我将其定性为“可接受的存量迁移缺口”，不是本次实现引入的新运行时回归。证据是：
- checker 本身按设计工作：`scripts/check-shared-memory-layers.ps1:145-169` 对 `当前任务.md` 缺 `entry_host` 只给 `Warnings`，但会对 `共享记忆协议.md` 缺引用、`恢复索引.md` / `中断任务.md` 缺 `derived_from` 给 `Errors`。
- 当前 live vault 仍是 legacy 形态：`.assistant/工作流/共享记忆协议.md:1-25` 没有 `docs/shared-memory-layers.md` 引用；`.assistant/运行时/恢复索引.md:1-3` 和 `.assistant/运行时/中断任务.md:1-10` 都没有 `derived_from`；`.assistant/运行时/当前任务.md:1-4` 也还是旧 frontmatter。
- 新增 contract test 是 fixture-based 并且本地通过，说明 checker 逻辑与 v2 目标合同是一致的：`tests/verify-shared-memory-layers.ps1:90-260`。
- 也就是说，这个 FAIL 反映的是 repo-local 共享记忆文件尚未被模板同步或运行态重写刷新，不是 resolver / loader / hot writer 在新代码下继续写错。

## Change Summary

Verdict: `revise`。

resolver / loader 收紧本身是连贯的：`Resolve-SharedMemoryVaultRoot`、`Assert-ProjectLocalVault`、`resolve-obsidian-memory-script.ps1`、`runtime-inbox-common.ps1` 已经把 runtime-touching 路径收口到项目本地 vault，并阻止静默回落到 agent-home runtime。`promote-runtime-inbox`、`repair-shared-memory`、`posttooluse` 这三条 hot path 的 `entry_host` / `derived_from` / lock schema 也都通过了针对性回归。当前剩余 blocker 是 `advance-stage` 这条主写入面还没有把 task-runtime mirror 升到同一合同。

## Evidence / Commands

- `git diff -- runtime-hooks/claude/posttooluse.js scripts/advance-stage.ps1 scripts/promote-runtime-inbox.ps1 scripts/repair-shared-memory.ps1 scripts/resolve-obsidian-memory-script.ps1 skills/obsidian-memory/scripts/check-shared-memory.ps1 skills/obsidian-memory/scripts/promote-runtime-inbox.ps1 skills/obsidian-memory/scripts/repair-shared-memory.ps1 skills/obsidian-memory/scripts/resolve-shared-memory-paths.ps1 skills/obsidian-memory/scripts/runtime-inbox-common.ps1 tests/verify-lite-footprint.ps1 tests/verify-promote-runtime-inbox.ps1 tests/verify-repair-shared-memory.ps1 tests/verify-runtime-hooks.ps1 tests/verify-shared-memory-layers.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-promote-runtime-inbox.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-repair-shared-memory.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-runtime-hooks.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-runtime-inbox.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-shared-memory-layers.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-contracts.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-footprint.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-shared-memory-layers.ps1 -VaultRoot .\.assistant -RepoRoot .`
- `Get-Content` / `Select-String` 检查 `scripts/advance-stage.ps1`、`skills/obsidian-memory/scripts/repair-shared-memory.ps1`、`skills/obsidian-memory/scripts/promote-runtime-inbox.ps1`、`skills/obsidian-memory/scripts/resolve-shared-memory-paths.ps1`、`.assistant/工作流/共享记忆协议.md`、`.assistant/运行时/*.md`
