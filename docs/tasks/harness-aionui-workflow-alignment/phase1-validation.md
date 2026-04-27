# Phase 1 Validation: Tool Profile Foundation

## Summary

Phase 1 validation result: PASS.

The current repository state supports optional `tool_profile` / `model` frontmatter, includes the three default profile descriptors under `agent-configs/profiles/`, validates profile/backend/model consistency, writes profile/model through `advance-stage.ps1`, and resolves the three prior review issues: Change Contract heading compatibility, `.codex` / `.gemini` ignore coverage, and fixture-producing test cleanup isolation.

## Scope

- Validate optional `tool_profile` / `model` support in `plan.md` frontmatter.
- Validate default profile descriptors for Claude, Codex, and Gemini.
- Validate `scripts/validate-lite-artifacts.ps1` behavior for old four-field plans, profile-backed plans, model aliases, profile/backend mismatches, and Change Contract placement.
- Validate `scripts/advance-stage.ps1` behavior for `-Profile` / `-Model`, profile default model writeback, mirror writeback, and mismatched profile rejection.
- Confirm the three prior issues are resolved:
  - Change Contract skeleton heading vs validator acceptance/order.
  - `.gitignore` coverage for local/generated `.codex/` and `.gemini/` skill directories.
  - Fixture-producing test cleanup isolation so passing runs do not silently leave task dirs behind.

## Inputs Reviewed

- `.gitignore`
- `README.md`
- `agent-configs/profiles/harness-default-claude.yaml`
- `agent-configs/profiles/harness-default-codex.yaml`
- `agent-configs/profiles/harness-default-gemini.yaml`
- `scripts/advance-stage.ps1`
- `scripts/validate-lite-artifacts.ps1`
- `vault-template/entry/advance-stage.ps1.template`
- `skills/plan/SKILL.md`
- `skills/orchestrator/SKILL.md`
- `skills/orchestrator/references/default-tool-profiles.md`
- `skills/orchestrator/references/lite-writing-guide.md`
- `skills/orchestrator/references/runbook.md`
- `skills/orchestrator/references/state-templates.md`
- `tests/verify-tool-profile.ps1`
- `tests/verify-change-contract.ps1`
- `tests/verify-lite-artifact-validator.ps1`
- `tests/verify-workflow-contracts.ps1`
- `tests/verify-lite-footprint.ps1`
- Prior review artifacts: `phase1-code-review.md`, `phase1-fix-review.md`

## Test Approach

- Static inspection confirmed `tool_profile` / `model` are documented, validated, and passed through the stage-advance shim.
- Static inspection confirmed profile descriptors include `name`, `backend`, `model`, `skills_dirs`, `enabled_skills`, `disabled_builtin_skills`, and `context`.
- Static inspection confirmed Change Contract examples now use exact `## Change Contract`, matching the validator's exact optional section name.
- Static inspection confirmed cleanup helpers record cleanup failures with `Add-Failure`, and fixture-heavy tests use isolated temp repo roots instead of writing test tasks into the source repo.
- Dynamic validation ran the focused PowerShell tests and git ignore check listed below.
- Cleanup isolation check counted generated task fixture directories before and after the test run: `0` before, `0` after.

## Findings

- PASS: `tests/verify-tool-profile.ps1` validates the default descriptors, old four-field frontmatter compatibility, valid profile-backed frontmatter, mismatched profile rejection, short model alias rejection, `advance-stage.ps1` mismatch rejection, and profile default model writeback to plan and mirror.
- PASS: `tests/verify-change-contract.ps1` validates legal Change Contract, opt-in absence, illegal `change_type`, placeholder-only `affected_paths`, cross-field bullet isolation, and section ordering.
- PASS: `tests/verify-lite-artifact-validator.ps1` validates the broader artifact contract remains intact.
- PASS: `tests/verify-workflow-contracts.ps1` validates stage advancement, explicit non-DONE `-Tool` requirement, gates, revise loops, TEST pass to DONE, and validator preflight.
- PASS: `tests/verify-lite-footprint.ps1` validates footprint expectations, `.gitignore` coverage, profile descriptor presence, and absence of the rejected annotated Change Contract heading.
- PASS: `git check-ignore -v .codex .gemini .codex/skills .gemini/skills` confirms `.gitignore` covers local/generated Codex and Gemini skill directories.
- PASS: No matching generated `docs/tasks/{tool-profile,change-contract,lite-*}` fixture directories were present before or after the validation run.

Exact checks run:

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-tool-profile.ps1`
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-change-contract.ps1`
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-lite-artifact-validator.ps1`
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-workflow-contracts.ps1`
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-lite-footprint.ps1`
- `git check-ignore -v .codex .gemini .codex/skills .gemini/skills`
- `Select-String -Path 'skills\plan\SKILL.md','skills\orchestrator\references\state-templates.md' -Pattern '## Change Contract  \(optional, opt-in\)' -SimpleMatch`
- Generated fixture directory count under `docs/tasks`: before `0`, after `0`.

## Risks / Gaps

- Phase 1 validates model IDs syntactically and rejects short aliases; it does not verify that a model is available from a live provider or valid for a specific backend.
- Profile YAML parsing intentionally covers Phase 1 top-level scalar fields needed by the scripts; deeper schema enforcement for list fields and AionUi ACP/team consumption remains a later-phase concern.
- Team preset creation and ACP skill invocation are outside Phase 1 and were not validated here.

## Conclusion

pass

Phase 1 tool profile foundation is validated for closure.

## Handoff

- delivery: `docs/tasks/harness-aionui-workflow-alignment/phase1-validation.md` updated with a direct PASS validation of Phase 1.
- follow_up: none for Phase 1 closure.
- current_state: Phase 1 validation passed; prior three review issues are resolved in the current repo state.
- next_actions:
  - Close Phase 1 if no additional leader-level acceptance gate is required.
