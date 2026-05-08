# Implementation

## Summary
- Fixed the Codex `config.toml` TOML scope regression in `install.ps1` by keeping preserved user-owned config before the managed block.
- Added a regression case in `tests/verify-update-managed-assets.ps1` that preloads root-level Codex config keys before install and asserts they remain before the first TOML table after managed update.
- Tightened the test harness install-step success override so it only treats `install.ps1` as successful when the output contains `Install summary:`.

## Root-Level Config Guard
The regression test writes:

- `model = "gpt-test"`
- `sandbox_mode = "workspace-write"`
- `[profiles.review]`

It then runs the managed-assets update path and checks that the root-level lines appear before the first TOML table. This catches the previous bug because prepending the managed block makes the first table `[managed.shared_paths]` / `[[skills.config]]`, leaving the user keys below managed skill tables.

## Verification
- PASS: `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-update-managed-assets.ps1`
- Direct scratch install check: generated `config.toml` starts with `model`, `sandbox_mode`, then `[profiles.review]`, then the managed block.
- Observation: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-update-managed-assets.ps1` still fails in existing non-new cases through the Windows PowerShell path; the new `codex-config-root-keys` case passes there. Treat the remaining Windows PowerShell failure as a separate verifier/runtime follow-up.
