# e9728e6b status

- status: implemented
- owner: codex-config-cleaner
- summary: cleaned the remaining active Gemini designer naming residue from the test-runner shell adapter and added an active-surface guard.

## Audit Scope

Searched active surfaces:

- `README.md`
- `skills/`
- `agent-configs/`
- `scripts/`
- `tests/`
- `vault-template/`
- `docs/aionui-integration/`
- `docs/team-write-authority.md`
- `docs/shared-memory-layers.md`
- `docs/工作流/`

Search terms included:

- `using-superpowers`
- `gemini-designer-main`
- `gemini-designer`
- `Gemini designer`
- `designer-main`
- old workflow compatibility names such as `codex-gemini`, `next_runner`, `claude-codex-gemini`, and retired phase-loading paths

## Classification

- Directly cleaned:
  - `skills/test-runner/scripts/ask_gemini.sh` still read `~/.config/gemini-designer/api_key` and told users to store API keys there. This was active behavior under the canonical `test-runner` skill, so it was changed to `~/.config/test-runner/api_key`.
- Test lock added:
  - `tests/verify-lite-footprint.ps1` now greps active surfaces and fails if `gemini-designer` reappears outside historical task docs or tests.
- Kept as explicit regression / compatibility evidence:
  - `using-superpowers` references under tests are negative/fixture assertions.
  - `gemini-designer-main` in `tests/verify-lite-footprint.ps1` is a path-absence lock.
  - `claude-codex-gemini-default` in workflow validator tests is an invalid-tool fixture.
- Left untouched:
  - Historical `docs/tasks/*` mentions of old names. These are task evidence and were not bulk rewritten.
  - `vault-template/首页.md` provenance link text to the original starter name. It is not an active workflow / skill / adapter path.

## Changes

- `skills/test-runner/scripts/ask_gemini.sh`
  - Default file-based ZenMux API key lookup moved from `~/.config/gemini-designer/api_key` to `~/.config/test-runner/api_key`.
  - Error guidance now points to `~/.config/test-runner/api_key`.
- `tests/verify-lite-footprint.ps1`
  - Added `Assert-GeminiDesignerRemovedFromActiveSurface`.
  - The guard searches active surfaces only, matching the existing `using-superpowers` active-surface policy.

## Validation

- PASS: `git diff --check`
- PASS: `bash -n skills/test-runner/scripts/ask_gemini.sh`
- PASS: `pwsh -NoProfile -File tests\verify-lite-footprint.ps1`
- PASS: `pwsh -NoProfile -File tests\verify-aionui-skill-contract.ps1`

## Residual Risk

- Users who stored the shell adapter API key only at the old `~/.config/gemini-designer/api_key` path must move it to `~/.config/test-runner/api_key` or use `ZENMUX_API_KEY` / `.env.local`.
- No Codex `config.toml` path was created, cleaned, migrated, deleted, normalized, or written in this task.
