# Code Review

## Verdict
FAIL

Scope note: this review stops at the blocking High finding below and is not an exhaustive pass over every changed documentation/workflow file.

## Findings
- High: `install.ps1:1025-1029` now writes the managed Codex TOML block before preserved user-owned config. The managed template contains `[[skills.config]]` array tables (`agent-configs/codex/config.shared.toml.template:10-32`), and TOML key/value pairs that follow an array table remain scoped to that last table until another table header appears. As a result, an existing user config such as `model = "..."` or `sandbox_mode = "..."` is no longer root-level after reinstall; it is appended under the last managed `skills.config` item. This silently breaks user Codex configuration while `tests/verify-installation.ps1` still passes because it only compares the managed block text and does not parse TOML semantics.

## Evidence
- Reproduced the generated bad order with a scratch user profile that already had root-level Codex settings:
  - preinstall config: `model = "gpt-test"` and `sandbox_mode = "workspace-write"`
  - after `install.ps1`, the file starts with the managed block and its final `[[skills.config]]`, then appends `model = "gpt-test"` below `# <<< claude-dev-harness managed block <<<`
  - that marker is only a comment, so the appended root settings are still in the previous TOML table scope
- Regression command:
  - `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-update-managed-assets.ps1`
  - Result: PASS, which confirms the current test suite does not catch this semantic config regression.
- Additional observation:
  - `powershell -ExecutionPolicy Bypass -File .\tests\verify-update-managed-assets.ps1` returned FAIL in this environment because the regression harness reads `$LASTEXITCODE` after PowerShell script invocations. The authoritative `pwsh` path passes, so I did not count that as the blocking finding for this change.

## Recommended Fix
- Keep preserved user-owned `config.toml` content before the managed block, or otherwise parse and rewrite TOML while guaranteeing root-level user keys stay at root. A simple restoration of the previous order in `Update-CodexConfig` avoids the TOML scope leak.
- Add a regression case that installs over an existing `config.toml` containing root-level keys and asserts they remain before the first `[managed.shared_paths]` / `[[skills.config]]` table, or validates the parsed TOML shape with a TOML parser.
