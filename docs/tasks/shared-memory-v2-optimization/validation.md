# Shared Memory v2 Validation

## Summary

Verdict: `PASS`

本轮验证确认 shared-memory-v2 的实现与已批准 plan、implementation-surface、plan-review、code-review、fix-review 结论一致。共享记忆主回归链、`advance-stage` 相关 workflow guard、以及新增静态 checker / footprint 均本地通过。此前 code review 的唯一阻塞点也已在 fix review 中闭合，没有在最终验证里复现。

## Inputs Reviewed

- `docs/tasks/shared-memory-v2-optimization/plan.md`
- `docs/tasks/shared-memory-v2-optimization/implementation-surface.md`
- `docs/tasks/shared-memory-v2-optimization/validation-baseline.md`
- `docs/tasks/shared-memory-v2-optimization/plan-review.md`
- `docs/tasks/shared-memory-v2-optimization/code-review.md`
- `docs/tasks/shared-memory-v2-optimization/fix-review.md`
- 实际改动面：
- `scripts/advance-stage.ps1`
- `runtime-hooks/claude/posttooluse.js`
- `scripts/promote-runtime-inbox.ps1`
- `scripts/repair-shared-memory.ps1`
- `scripts/resolve-obsidian-memory-script.ps1`
- `skills/obsidian-memory/scripts/check-shared-memory.ps1`
- `skills/obsidian-memory/scripts/promote-runtime-inbox.ps1`
- `skills/obsidian-memory/scripts/repair-shared-memory.ps1`
- `skills/obsidian-memory/scripts/resolve-shared-memory-paths.ps1`
- `skills/obsidian-memory/scripts/runtime-inbox-common.ps1`
- `tests/verify-shared-memory-layers.ps1`
- `tests/verify-promote-runtime-inbox.ps1`
- `tests/verify-repair-shared-memory.ps1`
- `tests/verify-runtime-hooks.ps1`
- `tests/verify-workflow-contracts.ps1`
- live repo-local vault evidence：
- `.assistant/工作流/共享记忆协议.md`
- `.assistant/运行时/当前任务.md`
- `.assistant/运行时/恢复索引.md`
- `.assistant/运行时/中断任务.md`

## Test Approach

- 共享记忆主回归链：验证 static checker、inbox/promotion/repair/hook/maintain/report 路径是否满足 v2 合同
- `advance-stage` 相关 guard：验证 mainline task mirror、tool/profile/writeback 与 workflow-descriptor 交互未回归
- footprint / docs presence：验证 shared-memory 新增资产确实进入 repo footprint
- live repo-local checker：专门分类 `.assistant` 当前 FAIL 究竟是运行态回归，还是可接受的 legacy migration gap

## Commands Run

- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-shared-memory-layers.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-runtime-inbox.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-promote-runtime-inbox.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-repair-shared-memory.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-runtime-hooks.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-triage-runtime-inbox.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-archive-memory-candidates.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-memory-health-report.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-memory-maintain.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-contracts.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-tool-profile.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-descriptor.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-footprint.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-shared-memory-layers.ps1 -VaultRoot .\.assistant -RepoRoot .`
- `Get-Content` / `Select-String` 检查：
- `scripts/advance-stage.ps1`
- `runtime-hooks/claude/posttooluse.js`
- `skills/obsidian-memory/scripts/repair-shared-memory.ps1`
- `skills/obsidian-memory/scripts/promote-runtime-inbox.ps1`
- `skills/obsidian-memory/scripts/resolve-shared-memory-paths.ps1`
- `.assistant/工作流/共享记忆协议.md`
- `.assistant/运行时/当前任务.md`
- `.assistant/运行时/恢复索引.md`
- `.assistant/运行时/中断任务.md`

## Findings

- `verify-shared-memory-layers.ps1` 通过，说明新 checker 的目标合同是自洽且可执行的：完整 fixture 会 PASS，legacy `当前任务.md` 缺 `entry_host` 只会 WARN，而 `derived_from` / lock schema 缺失会 FAIL。
- `verify-promote-runtime-inbox.ps1` 通过，说明 interrupted-task promotion 的 `task-runtime/v1.1` 现在会正确写出 `entry_host`，且外部 shared vault / cwd wrapper / literal selector 等现有行为未退化。
- `verify-repair-shared-memory.ps1` 通过，说明 repair 路径现在会把 `entry_host` 写入 `当前任务.md` 与 repair-side 自动补建的 `运行时/tasks/<task-id>.md`，并把 `derived_from` 写入 `恢复索引.md`，同时保留既有 lock / stale cleanup / idle/current-flow 兼容语义。
- `verify-runtime-hooks.ps1` 通过，说明 `posttooluse.js` 现在会把 `entry_host: claudecode` 写入 `runtime.lock.json`，并在重建 `恢复索引.md` 时带上 `derived_from`，且 foreign-lock inbox fallback 仍成立。
- `verify-workflow-contracts.ps1` 通过，说明此前 code review 阻塞点已闭合：`advance-stage` 主路径写出的 `.assistant/运行时/tasks/<task-id>.md` 现在包含 `entry_host: claudecode`，并由回归显式锁定。
- `verify-tool-profile.ps1` 与 `verify-workflow-descriptor.ps1` 通过，说明 shared-memory-v2 对 `advance-stage` 的更改没有破坏 Phase 2 已批准的 tool-profile / workflow-default / stdout/stderr 合同。
- `verify-lite-footprint.ps1` 通过，说明 `docs/shared-memory-layers.md`、`scripts/check-shared-memory-layers.ps1`、`tests/verify-shared-memory-layers.ps1` 以及相关 repo footprint 资产均已落地。

## Live Checker Classification

`C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-shared-memory-layers.ps1 -VaultRoot .\.assistant -RepoRoot .` 当前返回 `STATUS: FAIL`。

结论：这是 **acceptable legacy migration gap**，不是 **runtime regression**。

判定依据：

- checker 按设计工作，且新合同本身已经被 fixture-based regression 锁住：`tests/verify-shared-memory-layers.ps1` 本地通过。
- live FAIL 的具体原因全部来自仓库自带 repo-local `.assistant` 仍是 legacy 内容，而不是新 writer 继续产出错误 shape：
- `.assistant/工作流/共享记忆协议.md:1-20` 仍未引用 `docs/shared-memory-layers.md`
- `.assistant/运行时/恢复索引.md:1-3` 仍是旧的无 frontmatter 简表，没有 `derived_from`
- `.assistant/运行时/中断任务.md:1-10` 没有 `derived_from`
- `.assistant/运行时/当前任务.md:1-4` 仍缺 `entry_host`，而 checker 对这一项本来也只给 `Warnings`
- 这些 live 文件属于存量 repo-local vault 数据没有被模板同步或运行态重写刷新的问题；它们并不推翻本轮已通过的 hot-writer / regression 证据。

## Residual Risks

- live repo-local `.assistant` 目前仍不是 v2-clean 状态；只要这些现存文件未被手工刷新、模板同步或后续运行态重写覆盖，`check-shared-memory-layers.ps1 -VaultRoot .\.assistant` 仍会持续 FAIL。
- `check-shared-memory-layers.ps1` 仍是静态检测，不是运行时强制 hook；它能证明合同被测试覆盖，但不能自动修复现有 legacy vault 内容。
- `advance-stage.ps1` 依旧不参与 `runtime.lock.json` 协调，这是 implementation-surface 既有设计事实，本轮也未改变；当前验证确认“未回归”，不代表并发模型被扩大到新强制语义。

## Conclusion

`PASS`

shared-memory-v2 的已批准范围已经通过验证：resolver/loader 收紧、hot writer 的 `entry_host` / `derived_from` / best-effort writeback 合同、`advance-stage` 主路径 task mirror 的 `entry_host`、以及 shared-memory regression surface 均已成立。live repo-local `.assistant` checker FAIL 已明确归类为可接受的 legacy migration gap，而非运行态回归。
