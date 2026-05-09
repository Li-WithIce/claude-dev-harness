# 3274a8c8 status

- status: implemented
- owner: codex-config-cleaner
- summary: updated the vault home template display text from the old starter brand to the current Claude Dev Harness name, while preserving the existing link target.

## Changes

- `vault-template/首页.md`
  - Changed the visible link text from `CC-Codex-Gemini Companion Starter` to `Claude Dev Harness`.
  - Kept the existing GitHub URL unchanged.
- `tests/verify-lite-footprint.ps1`
  - Added a directory-level visible-text lock for `vault-template/` so the old complete Gemini starter branding cannot be reintroduced in any active vault template file.
  - The lock ignores Markdown link URL targets so the existing historical GitHub URL can remain unchanged while the visible display text stays neutral.

## Validation

- PASS: `git diff --check`
- PASS: `pwsh -NoProfile -File tests\verify-lite-footprint.ps1`

## Fixup

- `12e22270`: strengthened the old-brand regression lock from a single homepage assertion to a `vault-template/` directory-level scan for:
  - `CC-Codex-Gemini Companion Starter`
  - `CC-Codex-Gemini`
  - `Gemini Companion`
- Did not forbid generic `Companion Starter`.

## Notes

- Did not delete or modify Claude/Gemini explicit compatibility surfaces.
- Did not touch `%USERPROFILE%\.codex\config.toml`.
