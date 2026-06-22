# Test Report

## Summary
- Case Artifact advisory protocol is delivered with workflow documentation, template, plan/review/test writing rules, and regression coverage.

## Scope
- Covered optional `case.md` applicability, advisory-only boundaries, forbidden second-truth fields, artifact declaration guidance, TEST/Handoff expectations, footprint locks, and live validator baseline behavior.

## Inputs Reviewed
- `docs/tasks/session-case-artifact/plan.md`
- `docs/工作流/case-artifact.md`
- `vault-template/模板/case.md`
- `skills/orchestrator/references/lite-writing-guide.md`
- `skills/plan/SKILL.md`
- `skills/review/SKILL.md`
- `skills/test/SKILL.md`
- `tests/verify-lite-footprint.ps1`
- `tests/verify-lite-artifact-validator.ps1`

## Test Approach
- Ran `Select-String -Path docs/工作流/case-artifact.md -Pattern 'case.md|advisory-only|work_type|second truth'`.
- Ran `Select-String -Path skills/plan/SKILL.md,skills/review/SKILL.md,skills/test/SKILL.md,skills/orchestrator/references/lite-writing-guide.md -Pattern 'case.md|Case Artifact|case artifact'`.
- Ran `Test-Path 'vault-template/模板/case.md'`.
- Ran `pwsh -NoProfile -File tests/verify-lite-footprint.ps1`.
- Ran `pwsh -NoProfile -File tests/verify-lite-artifact-validator.ps1`.
- Ran `pwsh -NoProfile -File .assistant/entry/validate-lite-artifacts.ps1 -TaskId session-case-artifact`.
- Ran `git diff --check`.

## Findings
- `docs/工作流/case-artifact.md` defines `case.md` as optional advisory evidence for long debug, incident, or complex bug tasks, and keeps `plan.md` / `test.md` as the canonical stage and validation artifacts.
- `vault-template/模板/case.md` includes summary, reproduction, timeline, evidence, commands, environment, resolution, and open gaps sections.
- PLAN/REVIEW/TEST writing rules now require future tasks that enable `case.md` to declare it in `artifacts:` and keep it free of stage/status/verdict/tool/current pointer or Handoff conclusion fields.
- The current task does not declare or create `docs/tasks/session-case-artifact/case.md`; that is intentional because this task delivers the protocol and template, not a debug case evidence bundle.
- Regression scripts and the task validator return PASS. The task validator still emits warning-only artifact drift for the two Chinese paths because git status reports them in quoted form, but no error is produced and no hard gate changes were introduced.

## Risks / Gaps
- The non-ASCII path drift warning is noisy but advisory-only. Removing that warning cleanly would require a separate validator normalization task because this task intentionally did not modify `scripts/validate-lite-artifacts.ps1`.
- `case.md` has no schema parser or runtime consumer by design; misuse is guarded through writing rules, review checks, and TEST/Handoff documentation rather than a hard validator gate.

## Conclusion
pass

## Handoff
- delivery: Added optional Case Artifact documentation, template, PLAN/REVIEW/TEST/orchestrator writing guidance, footprint locks, live validator baseline update, and current-task implementation/review/test evidence.
- follow_up: none blocking; a separate P3 validator normalization task may be considered later if advisory drift warnings for non-ASCII paths become distracting.
- artifact: Declared artifacts are delivered: `docs/工作流/case-artifact.md`, `vault-template/模板/case.md`, and `docs/tasks/session-case-artifact/plan.md`; current-task `case.md` was not declared or created because this task is the protocol carrier.
- drift: `.assistant/entry/validate-lite-artifacts.ps1 -TaskId session-case-artifact` returns STATUS: PASS with two warning-only quoted-path drift messages for declared Chinese paths; no hard validation drift, missing declared artifact, or second-truth field was found.
- follow_up_decision: No follow-up blocks DONE; optional validator path normalization should stay separate from this advisory artifact task.
- memory_spec_update: No shared memory or spec update required beyond workflow runtime mirror written by `advance-stage.ps1`.
- current_state: Ready for `TEST -> DONE` after final validator/regression commands pass.
- key_decisions:
  - decision: `case.md` remains optional advisory evidence only.
    why: It preserves Trellis-like lightweight investigation context without adding stages, runtime, schema hard gates, or a second task truth source.
  - decision: Current task does not dogfood its own `docs/tasks/session-case-artifact/case.md`.
    why: The plan's declared artifacts are the protocol doc, template, and plan evidence; an empty case evidence file would contradict the guidance against creating `case.md` for non-debug tasks.
- next_actions:
  - Run final task validator and regression commands.
  - Advance `session-case-artifact` from TEST to DONE with `.assistant/entry/advance-stage.ps1`.
