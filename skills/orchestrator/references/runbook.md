# Execution Runbook

This runbook describes how orchestrator bootstraps, advances, recovers, and closes a development-harness task.

`handoff.md` 在这套流程中不是只在末尾生成一次的交付文档，而是从 bootstrap 开始持续刷新的滚动状态文档；当 stage 进入 `HANDOFF` 时，它同时成为最终交付快照。

## 1. Bootstrap a New Task

Before any automatic progression, confirm:

- The task identity is known
- The absolute path to `.assistant/orchestration/current-flow.md` is known for health gating
- Approved inputs are explicit:
  - requirement review
  - UI review (`present` / `missing` / `not-applicable`)
  - technical review (`present` / `absent`)
- A tool profile exists for the current stage
- If a repo preset is used, the preset is explicitly recorded as `tool_profile_source: repo-preset`

Bootstrap steps:

1. Resolve task identity
2. Resolve `entry_tool`, `tool_profile_id`, `tool_profile_source`, current stage binding, `fallback_policy`, and any declared `fallback_bindings`
3. Read repo context and summarize affected modules, dependencies, and risks
4. Initialize `current-flow.md` with `mode: fast-track` or `mode: full`
5. Record approved inputs and whether `DELTA_SPEC` is required
6. Initialize or refresh `handoff.md` as the current-stage snapshot
7. Mirror the task into shared runtime
8. Run the health gate

## 2. INTAKE

INTAKE consumes upstream approved inputs. It does not replay requirement review, UI review, or technical design review as internal stages.

Decision rules:

- Requirement review is always required
- UI review is required only when the task changes user-facing UI; otherwise record `ui review: not-applicable`
- Technical review is optional enhancement input
- If current inputs are sufficient, advance directly to PLAN
- If current inputs are insufficient, create or refresh `docs/<task-id>/spec.md` as a delta-spec and loop inside INTAKE until development boundaries are usable

## 3. PLAN

PLAN produces the main execution artifact `docs/<task-id>/plan.md`.

Checklist:

1. `plan.md` states consumed inputs or links to `spec.md`
2. `plan.md` describes phased tasks, dependencies, verification, and handoff expectations
3. User confirms the plan before DEV
4. `current-flow.md` points `current_doc` to `docs/<task-id>/plan.md`

## 4. DEV

DEV produces implementation diff and `docs/<task-id>/implementation-notes.md`.

Rules:

- Only implement what the confirmed `plan.md` requires
- Refresh `implementation-notes.md` every DEV round
- Keep risks and reviewer watchouts explicit
- Do not advance to REVIEW(implementation) without a reviewable diff

## 5. REVIEW(implementation)

REVIEW(implementation) is the only built-in review stage in the development harness.

Decision rules:

- `review.md` must declare `review_verdict: pass | revise`
- `P0 / P1` -> loop back to DEV
- only `P2` -> may advance to TEST
- all open `P2` risks must be prepared for TEST and final handoff carry-over

## 6. TEST

TEST produces `docs/<task-id>/test.md`.

Decision rules:

- `pass` -> HANDOFF
- `fail` -> DEV
- `blocked` -> REVIEW(implementation) or DEV depending on blocker type

Do not claim pass without explicit evidence in `test.md`.

## 7. HANDOFF

HANDOFF is the terminal state of the development harness, but `handoff.md` should already exist as a rolling status document before this stage.

Required content:

- current stage and next stage
- consumed inputs
- delta-spec status
- gate basis
- latest change summary
- test conclusion
- artifact linkage
- residual risks / watchouts
- downstream notes

New writes must use `HANDOFF`, not `DONE`.

## 8. Recovery Order

If `current-flow.md` is missing or invalid, recover in this order:

1. `handoff.md`
2. `test.md`
3. `review.md`
4. `implementation-notes.md` + diff
5. `plan.md`
6. optional `spec.md`

If artifacts recover cleanly but `tool_profile_id` is missing, first check whether exactly one repo preset matches the declared tool availability. If not, stop and write `decision-needed.md`.

## 9. Legacy Compatibility

Compatibility rules for in-flight legacy tasks:

- Read legacy `DONE` as a temporary alias for terminal completion only during migration
- Never write new terminal state as `DONE`
- If legacy state and current harness semantics disagree, stop and write `decision-needed.md`
- Repair old `current-flow.md` / `handoff.md` mappings before progression

## 10. Mandatory Close-out Steps

Every advance, loop-back, fallback, or recovery must end with:

1. Refresh `.assistant/orchestration/current-flow.md`
2. Append `.assistant/orchestration/stage-history.md`
3. Refresh `.assistant/orchestration/handoff.md` as the latest rolling snapshot
4. Update the shared runtime mirror
5. Run `..\..\scripts\memory-health.ps1 -VaultRoot {VAULT_PATH} -OrchestratorFlowPath <absolute-path-to-current-flow.md>`
6. Confirm `STATUS: PASS`
