# Status: install.ps1 TOML Order Regression

## Outcome
Covered and verified. No additional TOML-order patch was needed in this task because the implemented state already keeps preserved user-owned `config.toml` content before the managed block.

## Evidence
- `install.ps1` now writes:
  - sanitized user-owned TOML first
  - blank line
  - managed block
- `tests/verify-update-managed-assets.ps1` includes `codex-config-root-keys`, which seeds root-level `model` and `sandbox_mode` before install and asserts they remain before the first TOML table.

## Verification
- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-update-managed-assets.ps1`
- PASS: `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-update-managed-assets.ps1`

## Related Artifacts
- Original review finding: `docs/tasks/2422b106/code-review.md`
- Implementation note: `docs/tasks/fe7a1f34/implementation.md`
- Verifier report: `docs/tasks/59a651ca/test.md`
