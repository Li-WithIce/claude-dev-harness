# Test Report

## Summary
- Subtask Roadmap advisory artifact protocol is delivered with workflow documentation, template, plan/review/test writing rules, and regression coverage.

## Scope
- Covered optional `subtasks.yaml` and `docs/roadmaps/<slug>/items.yaml` applicability, advisory-only boundaries, forbidden second-truth fields, artifact declaration guidance, TEST/Handoff expectations, footprint locks, and live validator baseline behavior.

## Inputs Reviewed
- `docs/tasks/subtask-roadmap-artifact/plan.md`
- `docs/工作流/subtask-roadmap-artifact.md`
- `vault-template/模板/subtasks.yaml`
- `skills/orchestrator/references/lite-writing-guide.md`
- `skills/plan/SKILL.md`
- `skills/review/SKILL.md`
- `skills/test/SKILL.md`
- `tests/verify-lite-footprint.ps1`
- `tests/verify-lite-artifact-validator.ps1`

## Test Approach
- Ran `Select-String -Path docs/工作流/subtask-roadmap-artifact.md -Pattern 'subtasks.yaml|docs/roadmaps|advisory-only|advance-stage|second truth'`.
- Ran `Select-String -Path vault-template/模板/subtasks.yaml -Pattern 'schema_version|items|task_id|depends_on|acceptance|forbidden'`.
- Ran `Select-String -Path skills/plan/SKILL.md,skills/review/SKILL.md,skills/test/SKILL.md,skills/orchestrator/references/lite-writing-guide.md -Pattern 'subtasks.yaml|Subtask Roadmap|roadmap artifact|docs/roadmaps'`.
- Ran `Select-String -Path docs/工作流/subtask-roadmap-artifact.md,vault-template/模板/subtasks.yaml -Pattern '^\s*(stage|status|verdict|tool|current_phase|next_action|active_task|current_pointer|handoff_conclusion|done|state|progress|percent|complete)\s*:'`.
- Ran `pwsh -NoProfile -File tests/verify-lite-footprint.ps1`.
- Ran `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`.
- Ran `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId subtask-roadmap-artifact`.
- Ran `git diff --check`.

## Findings
- `docs/工作流/subtask-roadmap-artifact.md` defines task-local `docs/tasks/<task-id>/subtasks.yaml` and cross-task `docs/roadmaps/<slug>/items.yaml` as optional advisory breakdown artifacts.
- `vault-template/模板/subtasks.yaml` includes schema_version, summary, owner, items, task_id, title, type, depends_on, acceptance, artifacts, notes, open_gaps, and forbidden field guidance.
- PLAN/REVIEW/TEST writing rules now require future tasks that enable a subtask roadmap artifact to declare the actual artifact path in `artifacts:` and keep it free of stage/status/verdict/tool/current pointer, scheduler, team board state, or Handoff conclusion fields.
- The current task does not declare or create `docs/tasks/subtask-roadmap-artifact/subtasks.yaml`; that is intentional because this task delivers the protocol and template, not a parent/child roadmap instance.
- Regression scripts and the task validator return PASS. The task validator emits warning-only artifact drift for the two Chinese paths because git status reports them in quoted form, but no error is produced and no hard gate changes were introduced.

## Risks / Gaps
- The non-ASCII path drift warning is noisy but advisory-only. Removing that warning cleanly would require a separate validator normalization task because this task intentionally did not modify `scripts/validate-lite-artifacts.ps1`.
- Subtask roadmap artifacts have no schema parser, scheduler, team board integration, or runtime consumer by design; misuse is guarded through writing rules, review checks, and TEST/Handoff documentation rather than a hard validator gate.

## Conclusion
pass

## Handoff
- delivery: Added optional Subtask Roadmap documentation, template, PLAN/REVIEW/TEST/orchestrator writing guidance, footprint locks, live validator baseline update, and current-task implementation/review/test evidence.
- follow_up: none blocking; a separate P3 validator normalization task may be considered later if advisory drift warnings for non-ASCII paths become distracting.
- artifact: Declared artifacts are delivered: `docs/工作流/subtask-roadmap-artifact.md`, `vault-template/模板/subtasks.yaml`, and `docs/tasks/subtask-roadmap-artifact/plan.md`; current-task `subtasks.yaml` was not declared or created because this task is the protocol carrier.
- drift: `.assistant/entry/validate-lite-artifacts.ps1 -TaskId subtask-roadmap-artifact` returns STATUS: PASS with two warning-only quoted-path drift messages for declared Chinese paths; no hard validation drift, missing declared artifact, scheduler state, or second-truth field was found.
- follow_up_decision: No follow-up blocks DONE; optional validator path normalization should stay separate from this advisory artifact task.
- memory_spec_update: No shared memory or spec update required beyond workflow runtime mirror written by `advance-stage.ps1`.
- current_state: Ready for `TEST -> DONE` after final validator/regression commands pass.
- key_decisions:
  - decision: Subtask roadmap artifacts remain optional advisory breakdowns only.
    why: They preserve Trellis-like parent/child and dependency visibility without adding stages, queues, schedulers, team board state, runtime pointers, or a second task truth source.
  - decision: Current task does not dogfood its own `docs/tasks/subtask-roadmap-artifact/subtasks.yaml`.
    why: The plan's declared artifacts are the protocol doc, template, and plan evidence; an empty roadmap instance would contradict the guidance against creating roadmap artifacts for ordinary single-task work.
- next_actions:
  - Run final task validator and regression commands.
  - Advance `subtask-roadmap-artifact` from TEST to DONE with `.assistant/entry/advance-stage.ps1`.
