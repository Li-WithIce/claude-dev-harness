# Entry-router Phase 3 Alias Shrink Code Review

Reviewed implementation task: `12cee303`

## Findings

No blocking findings.

The Phase 3 change keeps `using-superpowers` as a legacy explicit alias while leaving the default workflow surface on `entry-router`. I did not find evidence that the old alias leaks back into `harness-lite`, role prompts, managed entry templates, generated PLAN command manifests, skills-index output, or team preset payloads.

## Evidence Reviewed

- `skills/using-superpowers/SKILL.md`: now only states the legacy alias behavior and points to canonical `../entry-router/SKILL.md`.
- `agent-configs/workflows/harness-lite.yaml`: PLAN remains `skills_whitelist: [plan, entry-router]`.
- `agent-configs/codex/config.shared.toml.template`: retains the disabled legacy alias path only as compatibility metadata.
- `scripts/validate-lite-artifacts.ps1`: keeps `using-superpowers` in the workflow skill advisory allowlist with an explicit legacy-compatibility comment.
- `tests/verify-lite-footprint.ps1`: now locks the alias shape and asserts the removed full entry-routing rules are absent from the legacy alias file.
- Active grep for `using-superpowers` across README, agent configs, scripts, skills, tests, vault template, and active docs only found the expected legacy allowlist hits.

## Verification

- `git diff --check` PASS
- `git grep -n "using-superpowers" -- README.md agent-configs scripts skills tests vault-template docs/aionui-integration docs/team-write-authority.md docs/shared-memory-layers.md docs/工作流` only expected legacy allowlist hits
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-footprint.ps1` PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-descriptor.ps1` PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-skill-manifest.ps1` PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-aionui-skill-contract.ps1` PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-update-managed-assets.ps1` PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-harness-entry.ps1` PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-team-preset.ps1` PASS
- `pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-team-orchestration.ps1` PASS

## Notes

- Historical references under `docs/tasks/*` and existing `.assistant` recovery history were treated as historical evidence, not active default surface.
- Remaining compatibility risk is limited to an external stale install that can invoke `/using-superpowers` but does not yet have `entry-router` installed. That is outside this repo diff and matches the implementation status note's residual risk.
