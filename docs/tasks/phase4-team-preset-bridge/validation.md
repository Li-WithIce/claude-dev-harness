---
task_id: phase4-team-preset-bridge
stage: VALIDATION
validator: harness-validator
verdict: PASS
---

# Phase 4 · Final Validation

Scope: final close-out validation of Phase 4 (team preset bridge) against
the approved `plan.md`. Not a redesign / not a re-review. Confirms that
implementation matches plan, the four P1s from `code-review.md` stay closed
in `fix-review.md`, and Phase 1 / 2 / 3 contracts have not regressed.

## Verdict

**PASS** — no new P1 / P2 found. All plan-mandated tests green; preset
schema and prefix set are byte-aligned across the five surfaces; env
opt-in is the only executable enforcement point; Phase 1–3 regression
set is clean.

## Plan conformance check

### `scripts/export-team-preset.ps1` (TODO 1)
- Parameters match plan: `-Workflow / -Output / [-Format yaml|json] / -RepoRoot`. `-Output` is mandatory; clean parameter error when missing (no constructor crash).
- Live JSON and YAML invocation produced output with the exact schema in `plan.md` lines 110-125: `name: harness-lite`, `version: 1`, `single_writer.owner: leader`, `single_writer.members_read_only_path_prefixes: ['.assistant/', 'docs/tasks/<task-id>/']`, then `members[5]` each carrying `role / backend / model / skills_whitelist / role_prompt_ref` (no inline prompt body, per TODO 1).
- Member order: plan-author → plan-reviewer → implementer → code-reviewer → tester (== `harness-lite.yaml` stage order; matches plan TODO 7 P2 / Q8).
- Per-member `backend` / `model` resolves through profile YAML (claudecode/claude-opus-4-7, codex/gpt-5.5/xhigh, gemini/gemini-2.5-pro), satisfying TODO 1 step 2 and TODO 7 P3.
- `skills_whitelist` per stage (`[plan, using-superpowers]`, `[review]`, `[implement]`, `[review]`, `[test, gemini-designer-main]`) matches `agent-configs/workflows/harness-lite.yaml`, satisfying TODO 7 P4.
- Prefixes are a fixed constant in the script, not a parameter (line 17), satisfying plan line 126 "导出脚本不参数化此集合".

### `skills/workflow-team/scripts/spawn-team.ps1` (TODO 2)
- Lines 77-83: explicit env gate `if ($env:AIONUI_TEAM_MODE -ne '1') { ... fail-closed ... }`. Smoke run with env unset emits exactly:
  - stdout single line `{"ok":false,"reason":"team_mode_disabled","task_id":"smoke-validation","workflow":"harness-lite","spawned_roles":[],"failed_role":"","errors":[...]}`.
  - stderr: `AIONUI_TEAM_MODE not set; team-mode is opt-in only`.
- This is the only executable enforcement point. orchestrator skill / SKILL.md / runbook only carry documentation references (verified below). Plan TODO 4 + R-CONTRACT-FAKE both honored.

### Single-writer prefix set (TODO 3 + TODO 5 + R0)
- Five surfaces verified byte-aligned on `['.assistant/', 'docs/tasks/<task-id>/']`:
  1. `scripts/export-team-preset.ps1` line 17 constant → live YAML output `single_writer.members_read_only_path_prefixes`.
  2. `agent-configs/role-prompts/<role>.md` × 5 — every file (plan-author, plan-reviewer, implementer, code-reviewer, tester) has both prefixes at lines 10–11 inside the Authority block.
  3. `docs/team-write-authority.md` lines 5–6 carry both prefixes as canonical truth source.
  4. `tests/verify-team-preset.ps1` P5 dynamically asserts byte-level equality between preset and authority doc (passes).
  5. `tests/verify-team-orchestration.ps1` O5 statically asserts both prefixes appear in every role-prompt and the SKILL.md (passes).
- No file outside this set introduces a competing prefix list; plan R0 / R-DRIFT closed.

### Orchestrator skill — documentation-only branch (TODO 4)
- `skills/orchestrator/SKILL.md` line 58 is the single mention of `AIONUI_TEAM_MODE`, framed as **Team mode (documentation only)** with explicit "env 校验由 `spawn-team.ps1` 自身 fail-closed 强制" pointer.
- `skills/orchestrator/references/runbook.md` lines 67–71 declare "唯一可执行强制点 = `skills/workflow-team/scripts/spawn-team.ps1`".
- No PowerShell `if ($env:AIONUI_TEAM_MODE ...)` exists outside `spawn-team.ps1`. Plan R-CONTRACT-FAKE closed.

### `docs/aionui-integration/team-preset.md` (TODO 6)
- File exists. Out of scope for runtime testing this round; plan only requires it as a contract reference.

### Test surfaces (TODO 7)
- `tests/verify-team-preset.ps1`: P1–P5 all green, exit 0.
- `tests/verify-team-orchestration.ps1`: O1–O6 all green, exit 0. O1/O6 confirm env-unset fail-closed even with MCP available; O2/O3 confirm 5-spawn order + payload correctness; O4 confirms first-failure abort + single-line `{"ok":false,...}` fallback; O5 confirms prefix-level static scan.
- Both tests reach assertion body cleanly (the prior StrictMode crashes from code-review F2/F3 stay closed).

### Footprint contract (`tests/verify-lite-footprint.ps1`)
- exit 0, STATUS PASS. All four new `.ps1` files explicitly listed with UTF-8 BOM:
  - `scripts/export-team-preset.ps1`
  - `scripts/generate-skills-index.ps1`
  - `scripts/invoke-harness-skill.ps1`
  - `skills/workflow-team/scripts/spawn-team.ps1`
- New skill directory `skills/workflow-team/` and `agent-configs/role-prompts/` paths whitelisted, satisfying TODO 7 + R-FOOTPRINT.

## Phase 1 / 2 / 3 regression

All non-team verifications run from clean working tree, exit 0, no failures:

- `verify-workflow-descriptor.ps1` — A1-A5 (descriptor validator advisory contract) + B1-B5 (resolution chain) + C1-C2 (Phase 1 writeback parity) + D1 + E1 + F1-F3 (workflow-default non-sticky writeback). Phase 1 / Phase 2 contracts intact.
- `verify-tool-profile.ps1` — profile descriptor validity, four-field frontmatter parity, tool/profile mismatch rejection, model alias rejection, advance-stage cli-tool path parity, advance-stage profile-default writeback. Phase 1 contracts intact.
- `verify-workflow-contracts.ps1` — advance-stage parsing under Windows PowerShell, PLAN→PLAN_REVIEW transition, invalid-stage rejection, IMPLEMENT gate freshness, TEST gate Handoff requirement, TEST→DONE, malformed-artifact gate. Stage machine intact.
- `verify-aionui-skill-contract.ps1` — A1-A4 / B1-B3 / C1-C2 / D1-D2 / E1. Phase 3 adapter / readonly-mode / skills_dir / invocation trace contracts intact.
- `verify-skill-manifest.ps1` — E1-E4. Per-task manifest write path, harness-lite whitelist parity, soft-failure stderr path, rollback cleanup. Phase 3 manifest contract intact.
- `verify-lite-artifact-validator.ps1` — DONE validator parity, frontmatter strictness, severity-heading strictness, stale-evidence rejection, Handoff strictness, spec strictness. No new plan.md sections introduced (frontmatter remains 4-field).

## Commands actually executed

All under `D:\data\claude-dev-harness`:
- `git log --oneline -20`
- `git status --short`
- `pwsh -NoProfile -File tests/verify-team-preset.ps1` → exit 0
- `pwsh -NoProfile -File tests/verify-team-orchestration.ps1` → exit 0
- `pwsh -NoProfile -File tests/verify-lite-footprint.ps1` → exit 0
- `pwsh -NoProfile -File tests/verify-workflow-descriptor.ps1` → exit 0
- `pwsh -NoProfile -File tests/verify-tool-profile.ps1` → exit 0
- `pwsh -NoProfile -File tests/verify-workflow-contracts.ps1` → exit 0
- `pwsh -NoProfile -File tests/verify-aionui-skill-contract.ps1` → exit 0
- `pwsh -NoProfile -File tests/verify-skill-manifest.ps1` → exit 0
- `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1` → exit 0
- `pwsh -NoProfile -File scripts/export-team-preset.ps1 -Format yaml -Output <tmp>` → exit 0, schema valid, prefix set verified
- `pwsh -NoProfile -File scripts/export-team-preset.ps1 -Format json -Output <tmp>` → exit 0, schema valid (verified earlier in fix-review)
- env-unset smoke on `skills/workflow-team/scripts/spawn-team.ps1 -TaskId smoke-validation` → stdout `{"ok":false,"reason":"team_mode_disabled",...}` + stderr "AIONUI_TEAM_MODE not set; team-mode is opt-in only"
- Grep / Glob spot checks on prefix consistency, AIONUI_TEAM_MODE call sites, role-prompt enumeration

## Files / regions read

- `docs/tasks/phase4-team-preset-bridge/plan.md` (full)
- `scripts/export-team-preset.ps1:1-60` (parameter block, prefix constant)
- `skills/workflow-team/scripts/spawn-team.ps1:77-83` (env gate)
- `skills/orchestrator/SKILL.md:56-60` (team-mode doc branch)
- `skills/orchestrator/references/runbook.md:67-71` (executable point reference)
- `docs/team-write-authority.md:1-30` (canonical prefix list)
- 5 × `agent-configs/role-prompts/<role>.md` (Authority block lines 10–11)
- `tests/verify-team-preset.ps1:79-289` (fixture + P1 export check)

## Residual risk (informational, not a blocker)

- **R-MCP** (carried from plan): the live AionUi `team_spawn_agent` schema is asserted only via mocks; actual end-to-end spawn against AionUi main process is not exercised by harness tests. Plan TODO 7 acknowledges this as out-of-scope for static verification; the `docs/aionui-integration/team-preset.md` contract reference is intentional. No action required this Phase.
- **`294bf604`** (`verify-update-managed-assets` regression) is a separate task and is **not** a Phase 4 blocker per Leader's directive. It is left out-of-scope for this validation.

## File existence

`docs/tasks/phase4-team-preset-bridge/validation.md` — confirmed written this session.
