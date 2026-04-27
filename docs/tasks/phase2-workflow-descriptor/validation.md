# Phase 2 Validation: Workflow Descriptor

## Summary

Phase 2 validation result: PASS.

当前仓库状态已经满足 Phase 2 的已批准范围：`scripts/advance-stage.ps1` 实现了 `cli-tool -> cli-profile -> workflow-default -> throw` fallback；`pure cli-tool` 会清空下一 stage 的 `tool_profile/model`；`workflow-default` 会把 descriptor 的 `default_profile/model` 写回 `plan.md` 与 task mirror；当前 stage 的 `tool_profile/model` 保持 non-sticky；解析 trace 只写 stderr，stdout 仍保持 `<stage> | <tool>`；`scripts/validate-lite-artifacts.ps1` 的 workflow descriptor audit 保持 advisory 语义；invalid `-Profile` 现在 fail closed，不再静默落到 `workflow-default`。

## Scope

- Validate Phase 2 workflow descriptor foundation against `docs/tasks/phase2-workflow-descriptor/plan.md`.
- Validate fallback / writeback / non-sticky / stderr+stdout contracts.
- Validate advisory validator behavior and exit-code semantics.
- Validate invalid explicit `-Profile` now fails closed without falling through to `workflow-default`.
- Confirm the required regression gates pass:
  - `tests/verify-workflow-descriptor.ps1`
  - `tests/verify-tool-profile.ps1`
  - `tests/verify-workflow-contracts.ps1`
  - `tests/verify-lite-artifact-validator.ps1`
  - `tests/verify-lite-footprint.ps1`

## Inputs Reviewed

- `docs/tasks/phase2-workflow-descriptor/plan.md`
- `docs/tasks/phase2-workflow-descriptor/code-review.md`
- `docs/tasks/phase2-workflow-descriptor/fix-review.md`
- `agent-configs/workflows/harness-lite.yaml`
- `agent-configs/profiles/harness-default-claude.yaml`
- `agent-configs/profiles/harness-default-codex.yaml`
- `agent-configs/profiles/harness-default-gemini.yaml`
- `scripts/advance-stage.ps1`
- `scripts/validate-lite-artifacts.ps1`
- `tests/verify-workflow-descriptor.ps1`
- `tests/verify-tool-profile.ps1`
- `tests/verify-workflow-contracts.ps1`
- `tests/verify-lite-artifact-validator.ps1`
- `tests/verify-lite-footprint.ps1`

## Test Approach

- Static inspection:
  - Confirm `Resolve-FallbackTool` implements `cli-tool -> cli-profile -> workflow-default -> none`, and that `cli-profile` failure no longer gets swallowed (`scripts/advance-stage.ps1:530-603`).
  - Confirm `Resolve-ProfileSelection` applies the three writeback paths: `workflow-default` writes descriptor profile/model, pure `cli-tool` clears profile/model, and other explicit profile/model cases reuse Phase 1 behavior (`scripts/advance-stage.ps1:716-736`).
  - Confirm plan/task mirror/current-task writeback consumes the resolved profile/model and stdout remains `"$nextStage | $nextTool"` (`scripts/advance-stage.ps1:1031-1100`).
  - Confirm workflow descriptor audit only adds warnings and does not affect fatal exit behavior (`scripts/validate-lite-artifacts.ps1:453-520`, `1151-1192`).
- Dynamic validation:
  - Run the five required PowerShell verify scripts from repo root.
  - Use the new `verify-workflow-descriptor.ps1` cases as the primary executable contract for fallback order, fail-closed invalid `-Profile`, stderr/stdout split, workflow-default writeback, and non-sticky semantics.

## Findings

- PASS: `tests/verify-workflow-descriptor.ps1` passed end-to-end. It covers:
  - `B1` pure `cli-tool` clearing path.
  - `B2` valid `cli-profile`.
  - `B3` invalid `cli-profile` fail-closed without `workflow-default` fallback.
  - `B4/B5` `workflow-default` fallback and final `requires -Tool` path.
  - `C1/C2` explicit `-Tool + -Profile` compatibility and mismatch rejection.
  - `D1` advisory validator semantics with explicit `-Tool`.
  - `E1` stderr trace + exact stdout contract.
  - `F1/F2/F3` non-sticky resolution and descriptor-driven writeback.
- PASS: `tests/verify-tool-profile.ps1` passed and confirms Phase 1 profile/model compatibility remains intact, including descriptor validity, backend mismatch rejection, full model enforcement, pure `cli-tool` clearing path, and explicit profile default-model writeback.
- PASS: `tests/verify-workflow-contracts.ps1` passed, confirming the broader stage-advance contract still holds and that the Phase 2 changes did not break existing exact-output workflow behavior.
- PASS: `tests/verify-lite-artifact-validator.ps1` passed, confirming validator fatal semantics are unchanged for real errors.
- PASS: `tests/verify-lite-footprint.ps1` passed, confirming required docs/config/template footprints, `.gitignore` coverage for `/.codex/` and `/.gemini/`, profile/workflow assets, and BOM/file-shape expectations.
- PASS: No new P1/P2 findings were discovered in this validation pass.

Exact commands run from `D:\data\claude-dev-harness`:

- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-descriptor.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-tool-profile.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-workflow-contracts.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-artifact-validator.ps1`
- `C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify-lite-footprint.ps1`

## Risks / Gaps

- This validation pass did not rerun `tests/verify-installation.ps1`; that script requires an installed-workspace fixture and was outside the minimum required gate for this closure run.
- Model/profile validation remains repo-local and syntactic. It does not prove live provider availability for a given backend/model pair.
- The validation gates are strong for the approved Phase 2 surface, but they do not cover later-phase concerns such as team preset bridging or ACP schema behavior.

## Conclusion

PASS

Phase 2 workflow descriptor foundation is validated for closure.

## Handoff

- delivery: `docs/tasks/phase2-workflow-descriptor/validation.md` created with a direct PASS validation for Phase 2.
- follow_up: none for Phase 2 closure.
- current_state: required implementation, code review, fix review, and final validation are now all present; required Phase 2 verify gates passed in the current repo state.
- next_actions:
  - Leader can treat Phase 2 as closed unless a higher-level release gate requires additional installation-fixture validation.
