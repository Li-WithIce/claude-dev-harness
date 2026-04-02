# Gate Conditions

Each stage transition checks current-task artifacts, not fixed filenames.
Minimum structure rules are defined in [artifact-contracts.md](artifact-contracts.md).

Recommended automation:

- Run `scripts/validate-harness-artifacts.ps1 -CurrentFlowPath <absolute-path-to-current-flow.md>` before claiming an artifact gate is satisfied.

## Canonical Path Quick Reference

| Artifact | Canonical path |
|------|----------------|
| optional delta-spec | `docs/<task-id>/spec.md` |
| plan | `docs/<task-id>/plan.md` |
| implementation-notes | `docs/<task-id>/implementation-notes.md` |
| review | `docs/<task-id>/review.md` |
| test | `docs/<task-id>/test.md` |
| handoff | `docs/<task-id>/handoff.md` |

## Shared Runtime Checks

These checks apply to every stage transition in addition to artifact-specific gates.

- [ ] `..\..\scripts\memory-health.ps1 -VaultRoot {VAULT_PATH} -OrchestratorFlowPath <current-flow.md>` returns `STATUS: PASS`
- [ ] When the current task is active, `运行时/当前任务.md` and `运行时/tasks/<task-id>.md` resolve to the same `task_id`
- [ ] The shared runtime mirror is present and readable before advancing
- [ ] Newly written current-task markdown under `docs/<task-id>/` and shared runtime notes contain no suspected mojibake

## INTAKE -> PLAN

- [ ] Current-task identity is resolved
- [ ] Approved inputs are explicitly recorded in `current-flow.md` / `handoff.md`
- [ ] Approved requirement review is present
- [ ] If the task changes user-facing UI, approved UI review is present; otherwise `ui review: not-applicable` is explicitly recorded
- [ ] Technical design review is recorded as `present` / `absent`, not silently guessed
- [ ] If approved inputs are insufficient, either:
  - [ ] `spec.md` exists and satisfies the optional delta-spec contract
  - [ ] or `decision-needed.md` is written and progression is blocked

## PLAN -> DEV

- [ ] Current-task `plan.md` exists
- [ ] Current-task `plan.md` ownership is verifiable
- [ ] Structural validation passes for `plan.md`
- [ ] Current-task `plan.md` satisfies the minimum contract
- [ ] `plan.md` is user-confirmed
- [ ] If `spec.md` exists, it satisfies the optional delta-spec contract

## DEV -> REVIEW(implementation)

- [ ] A reviewable diff exists for the current task
- [ ] Current-task `implementation-notes.md` exists
- [ ] Structural validation passes for `implementation-notes.md`
- [ ] Current-task `implementation-notes.md` satisfies the minimum contract
- [ ] `current-flow.md` reflects the real runner and output paths for this round

## REVIEW(implementation) -> TEST

- [ ] Current-task `review.md` exists
- [ ] Current-task `review.md` ownership is verifiable
- [ ] Structural validation passes for `review.md`
- [ ] Current-task `review.md` satisfies the minimum contract
- [ ] `review_scope = implementation`
- [ ] `review_verdict = pass`
- [ ] No `P0` or `P1` findings remain
- [ ] Any `P2` risk is recorded for TEST / HANDOFF carry-over

If any `P0` or `P1` exists, REVIEW(implementation) must loop back to DEV.

## TEST -> HANDOFF

- [ ] Current-task `test.md` exists
- [ ] Current-task `test.md` ownership is verifiable
- [ ] Structural validation passes for `test.md`
- [ ] Current-task `test.md` satisfies the minimum contract
- [ ] Conclusion verdict is exactly `pass`

If the verdict is `fail`, loop back to DEV.
If the verdict is `blocked`, return to REVIEW(implementation) or DEV depending on the blocker.

## HANDOFF terminal check

- [ ] Current-task `handoff.md` exists
- [ ] Current-task `handoff.md` ownership is verifiable
- [ ] Current-task `handoff.md` satisfies the minimum contract
- [ ] `handoff.md` records current stage, gate basis, latest change summary, and artifact linkage
- [ ] `handoff.md` preserves open `P2` risks and downstream notes
- [ ] `handoff.md` records the test conclusion and consumed inputs
- [ ] New writes use `HANDOFF`, not `DONE`

## Hard Fail Cases

The gate fails immediately if any of the following is true:

- Missing or stale shared runtime mirror
- Missing stage binding for the current step or the next required step
- Attempting to skip REVIEW(implementation) and go directly from DEV to TEST
- Attempting to skip TEST and go directly to HANDOFF
- Advancing without explicit evidence in `test.md`
- Writing new terminal state as `DONE`
