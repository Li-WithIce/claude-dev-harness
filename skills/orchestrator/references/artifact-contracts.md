# Artifact Contracts

orchestrator gates depend on usable current-task artifacts, not just file existence.

## Shared Rules

- Resolve current-task artifacts in this order:
  1. Canonical task-scoped path
  2. Legacy file with matching `task_id` or `task_name` frontmatter
  3. If still ambiguous, stop automatic progression and write `decision-needed.md`
- A gate check always verifies:
  1. The current-task artifact exists when that artifact is required by the current stage
  2. The artifact belongs to the current task
  3. The artifact satisfies its minimum contract
- In the development harness, `plan.md` is the main document; `spec.md` is optional and only exists when `DELTA_SPEC` is triggered
- `handoff.md` is the rolling stage-status artifact for the current task; when stage = `HANDOFF`, it also becomes the final development-delivery snapshot consumed by downstream roles

## Optional delta-spec (`spec.md`)

Current-task `spec.md` is optional. When it exists, it must contain at least:

- `状态：草稿 | 待确认 | 已确认`
- `review_status：未审查 | 需修订 | 已收敛`
- `task_id` and `task_name`
- Why approved inputs are insufficient
- Delta scope / boundary clarifications
- Key constraints or assumptions
- Acceptance or verification deltas

Output path: `docs/<task-id>/spec.md`

Gate mapping: `spec.md` does not create a default stage by itself. It only supplements `INTAKE -> PLAN`.

## plan

Current-task `plan.md` must contain at least:

- `状态：草稿 | 待确认 | 已确认`
- `review_status：未审查 | 需修订 | 已收敛`
- `task_id`
- Task goal
- Approved inputs or delta-spec linkage
- Phased implementation steps
- Dependencies and risks
- Verification approach
- Handoff expectations / downstream watchouts

Output path: `docs/<task-id>/plan.md`

## implementation-notes

Current-task `implementation-notes.md` is the required DEV -> REVIEW handoff and must contain at least:

- What changed
- What did not change
- Risks
- Reviewer watchouts
- Verification already run

Output path: `docs/<task-id>/implementation-notes.md`

## review

Current-task `review.md` means implementation review and must contain at least:

- `task_id` and `task_name`
- `review_scope: implementation`
- `review_verdict: pass | revise`
- Findings list
- A severity for each finding, supporting at least `P0 / P1 / P2`
- Review summary with overall verdict

Output path: `docs/<task-id>/review.md`

Gate mapping: `review_verdict = revise` or any `P0` / `P1` -> loop back to DEV；`review_verdict = pass` with only `P2` or no findings -> can enter TEST, but risks must be preserved into `handoff.md`

## test

Current-task `test.md` must contain at least:

- `task_id` and `task_name`
- `# Test Report`
- `## Summary`
- `## Scope`
- `## Inputs Reviewed`
- `## Test Approach`
- `## Findings`
- `## Risks / Gaps`
- `## Conclusion`

Output path: `docs/<task-id>/test.md`

Under `## Conclusion`, there must be exactly one verdict word: `pass`、`fail`、or `blocked`.

Gate mapping:

- `pass` -> HANDOFF
- `fail` -> DEV
- `blocked` -> REVIEW(implementation) or DEV, depending on blocker type

## handoff

Current-task `handoff.md` is the rolling stage-status and delivery artifact and must contain at least:

- `task_id` and `task_name`
- Current `stage`, `next_stage`, and `handoff_reason`
- Approved inputs actually consumed
- Gate basis for the latest transition or attempted transition
- Delta-spec linkage when applicable
- Latest change summary / current status
- Test conclusion (`not-run` is allowed before TEST finishes; terminal `HANDOFF` must record the final verdict from `test.md`)
- Artifacts in scope
- Residual risks / watchouts
- Downstream consumption notes

Output path: `docs/<task-id>/handoff.md`

### Handoff Quality Rules

- Refresh `handoff.md` on every advance, loop-back, fallback, and recovery, not only at terminal delivery
- Do not claim `HANDOFF` without explicit `test.md` evidence
- Preserve all open `P2` items and known gaps
- Keep the latest change summary aligned with `implementation-notes.md`, `review.md`, and `test.md`
- Refresh `handoff.md` whenever stage, runner, fallback tier, reviewed diff scope, or downstream risk picture changes

## Legacy document-review artifacts

`spec-review.md` and `plan-review.md` may still exist for one-off document review flows, migration tasks, or pre-implementation checks, but they are not part of the default development harness stage machine.

## Structural Validation

### Required meta keys

| Artifact | Required meta |
|---------|---------------|
| `spec.md` | `状态`、`review_status`、`task_id`、`task_name` |
| `plan.md` | `状态`、`review_status`、`task_id` |
| `implementation-notes.md` | `task_id`、`task_name` |
| `review.md` | `task_id`、`task_name`、`review_scope`、`review_verdict` |
| `test.md` | `task_id`、`task_name` |
| `handoff.md` | `task_id`、`task_name`、`stage`、`next_stage`、`handoff_reason` |

### Required keyword groups

#### spec.md

- insufficiency reason
- delta boundary
- constraints or assumptions
- verification delta

#### plan.md

- approved inputs or delta-spec linkage
- task breakdown
- dependencies
- verification
- handoff expectations

#### implementation-notes.md

- what changed
- what did not change
- risks
- reviewer watchouts

#### review.md

- findings
- severities
- summary
- verdict

#### test.md

- summary
- findings
- conclusion

#### handoff.md

- consumed inputs
- gate basis
- current status
- artifacts
- test conclusion
- residual risks
- downstream notes
