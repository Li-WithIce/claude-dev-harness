# Status: Codex-first Remaining Consistency Fixes

## Outcome
Completed the remaining verifier-discovered consistency items.

## Fixes Included
- `install.ps1`: shortened backup leaf names with a stable SHA-256 suffix so Windows PowerShell 5.1 scratch update cases no longer fail on long paths.
- `scripts/update-managed-assets.ps1`: normalized successful `install.ps1` step handling instead of trusting inherited native `$LASTEXITCODE`.
- `scripts/advance-stage.ps1`: replaced hardcoded `entry_host: claudecode` with the resolved next-stage tool.
- `tests/verify-workflow-contracts.ps1`: now asserts `entry_host: codex` for the Codex PLAN -> PLAN_REVIEW transition.

## Verification
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-update-managed-assets.ps1`
- PASS: `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-update-managed-assets.ps1`
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-contracts.ps1`
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-descriptor.ps1`
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-footprint.ps1`
- PASS: `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-team-orchestration.ps1`

## Non-blocking
- `powershell.exe` execution of `tests\verify-team-orchestration.ps1` is not a usable gate in this host; the script's child-shell helper path does not emit a report there. The same test passes under `pwsh`.
