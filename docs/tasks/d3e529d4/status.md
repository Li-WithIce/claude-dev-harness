# d3e529d4 status

- status: implemented
- owner: codex-config-cleaner
- summary: install/update workflow no longer creates, cleans, normalizes, backs up, or writes Codex user `config.toml`; Harness-managed Codex TOML is written only to `managed_config.toml`.

## Changes

- `install.ps1`
  - Replaced `Update-CodexConfig` with `Update-CodexManagedConfig`.
  - Removed the old user `config.toml` read/sanitize/write path and its TOML cleanup helpers.
  - Removed the install-time `config.toml` target path from the Codex config update call.
- `tests/verify-installation.ps1`
  - Treats `config.toml` as optional user-owned state.
  - Reports legacy managed blocks, leaked Harness skill paths, or lone CR bytes as warnings instead of install failures, because workflow no longer mutates the file.
- `tests/verify-update-managed-assets.ps1`
  - Replaced the root-key ordering regression with an exact-content preservation regression.
  - Added a regression that asserts install/update does not create `config.toml` when absent.
- `agent-configs/codex/README.md`
  - Documents the new boundary: workflow writes only `managed_config.toml`; user `config.toml` is not created, cleaned, or rewritten.

## Validation

- PASS: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-update-managed-assets.ps1`
- FAIL, unrelated live workspace baseline: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-installation.ps1 -WorkspaceRoot D:\data\claude-dev-harness -RepoRoot D:\data\claude-dev-harness`
  - Existing failures: live workspace `.gitignore` lacks managed entries; live `.assistant\entry\{AGENTS.md,GEMINI.md,advance-stage.ps1,validate-lite-artifacts.ps1}` files are missing; shared-memory health fails.
  - Codex config checks in that run passed with no warnings.

## Repair 94403f80

- Added `codex-config-legacy-managed-block-is-preserved` to `tests/verify-update-managed-assets.ps1`.
- The fixture seeds user `.codex\config.toml` with an old `# >>> claude-dev-harness managed block >>>` section, a legacy Harness `[[skills.config]]` path, and a user-owned `[[skills.config]]`.
- The assertion compares the post-install/update file byte-for-byte against the original fixture, so Harness cannot clean, migrate, rewrite, delete, or normalize that user file without failing the test.
- The same fixture asserts managed `[[skills.config]]` is still written to `.codex\managed_config.toml`.

### Repair Validation

- PASS: `git diff --check`
- PASS: `pwsh -NoProfile -File tests\verify-update-managed-assets.ps1`
  - Expected case status: `codex-config-legacy-managed-block-is-preserved: WARN`, because `verify-installation.ps1` intentionally warns when user-owned `config.toml` still contains a legacy managed block.
- PASS: `pwsh -NoProfile -File tests\verify-lite-footprint.ps1`
