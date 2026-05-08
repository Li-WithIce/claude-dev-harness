# Fix: advance-stage entry_host Bias

## Summary
- Removed the hardcoded `entry_host: claudecode` writeback from `scripts/advance-stage.ps1`.
- Task mirror frontmatter now writes `entry_host: $nextTool`.
- Shared `运行时/当前任务.md` content now receives `-EntryHost $nextTool` and writes that value in frontmatter.
- Updated `tests/verify-workflow-contracts.ps1` so the PLAN -> PLAN_REVIEW success case expects `entry_host: codex` when the next assigned tool is Codex.

## Verification
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-contracts.ps1`
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-descriptor.ps1`

## Notes
- `DONE` continues to resolve `tool: none`, so its task mirror/current-task `entry_host` will also be `none`.
- This keeps `entry_host` aligned with the actual next-stage backend instead of preserving the old Claude Code default.
