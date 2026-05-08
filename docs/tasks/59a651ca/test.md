# Codex-first Workflow Regression Verification

## Verdict
PASS, with one verifier-side compatibility fix landed.

## Fix Applied During Verification
- `install.ps1`: added `Get-BackupSafeName` and switched backup leaf names from full sanitized paths to a short prefix plus SHA-256 hash. This fixes Windows PowerShell 5.1 failures when scratch workspace case names make backup paths exceed the legacy path limit.
- `scripts/update-managed-assets.ps1`: made the `install.ps1` step use the script result instead of inherited native `$LASTEXITCODE` noise.
- `tests/verify-update-managed-assets.ps1`: made the harness normalize successful `install.ps1` setup calls before reading the result.

## Evidence
- PASS: PowerShell parser check for `install.ps1`, `scripts/update-managed-assets.ps1`, `skills/codex/scripts/ask_codex.ps1`, `tests/verify-installation.ps1`, and `tests/verify-update-managed-assets.ps1`.
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-update-managed-assets.ps1`
  - 8 checks passed, including `codex-config-root-keys`, cwd autodetect, managed-comment restore, and LF-only `.gitignore`.
- PASS: `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-update-managed-assets.ps1`
  - Same 8 checks passed.
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-descriptor.ps1`
  - 17 checks passed, no failures.
- PASS: `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-team-orchestration.ps1`
  - O1-O6 checks passed, no failures.
- PASS: `skills/codex/scripts/ask_codex.ps1 -ReadOnly -Ephemeral`
  - Console artifact: `docs/tasks/59a651ca/ask-codex-ephemeral-console.txt`
  - Output artifact: `docs/tasks/59a651ca/ask-codex-ephemeral-output.md`
  - Response body was exactly `OK`.

## Non-blocking Observations
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-team-orchestration.ps1` did not produce a useful test report in this host and exited non-zero after a long run. The same script passes under `pwsh`, and its helper intentionally spawns the current shell, so the `pwsh` result is the valid gate here.
- A live `tests/verify-installation.ps1` against `D:\data\claude-dev-harness` still reports existing workspace-state issues: missing `.gitignore` managed entries, missing `.assistant\entry\*` files, and shared-memory health failure. Scratch install/update verification is green, so this is not counted as a Codex-first regression blocker.
