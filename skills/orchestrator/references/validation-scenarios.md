# Validation Scenarios

Use these scenarios to verify the development harness did not regress to the old full-lifecycle workflow.

## 1. Standard Bootstrap With Approved Inputs

- requirement review: present
- UI review: not-applicable
- technical review: absent
- `current-flow.md` does not exist

Expected:

- orchestrator bootstraps a new task in `INTAKE`
- `current-flow.md` records approved inputs explicitly
- `handoff.md` is initialized as a rolling stage snapshot, not deferred until terminal delivery
- flow advances to PLAN without forcing full `spec.md`

## 2. Optional Technical Review Is Consumed, Not Promoted to a Stage

- requirement review: present
- UI review: present
- technical review: present

Expected:

- technical review is recorded as enhancement input
- stage machine remains `INTAKE -> PLAN -> DEV -> REVIEW(implementation) -> TEST -> HANDOFF`

## 3. DELTA_SPEC Is Triggered Only When Inputs Are Insufficient

- requirement review: present
- UI review: not-applicable
- approved inputs still miss boundary or constraint details

Expected:

- orchestrator keeps stage in INTAKE
- `docs/<task-id>/spec.md` is created as optional delta-spec
- progression stays blocked until delta-spec becomes usable

## 4. PLAN Becomes the Main Document

- `docs/<task-id>/plan.md` exists
- `docs/<task-id>/spec.md` may or may not exist

Expected:

- `plan.md` contains consumed inputs or delta-spec linkage
- `plan.md` includes implementation phases, verification, and handoff expectations
- DEV only starts after plan confirmation

## 5. REVIEW With Only P2 Advances to TEST

- `review.md` exists
- `review_scope: implementation`
- `review_verdict: pass`
- findings contain only `P2`

Expected:

- flow advances to TEST
- open risks are preserved in the rolling `handoff.md` for TEST and final handoff

## 6. TEST Fail Loops Back to DEV

- `test.md` verdict is `fail`

Expected:

- flow returns to DEV
- no terminal state is written

## 7. TEST Pass Enters HANDOFF, Not DONE

- `test.md` verdict is `pass`

Expected:

- flow enters `HANDOFF`
- `handoff.md` keeps the same rolling structure and now records final `test_conclusion: pass`
- new writes use `HANDOFF`
- no new terminal state is written as `DONE`

## 8. Legacy DONE Is Read but Not Rewritten

- legacy `current-flow.md` or `handoff.md` uses `DONE`

Expected:

- recovery maps it safely to terminal completion semantics
- migration keeps legacy read-compatibility
- new writes after recovery use `HANDOFF`

## 9. Shared Runtime Health Gate Blocks Progression

- shared runtime mirror is stale or missing

Expected:

- health gate returns non-pass
- orchestrator blocks progression
- `decision-needed.md` or repair flow is triggered

## 10. Mirror Consistency Uses the Full Matrix

- D2 mirror sync has completed

Expected:

- validation covers:
  - `using-superpowers`
  - `orchestrator + references`
  - `spec/plan`
  - `implement/review/test`
- single-file spot check is not accepted as enough evidence
