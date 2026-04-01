# State Templates

## current-flow.md

`memory-health.ps1 -OrchestratorFlowPath ...` resolves current-task docs from `current-flow.md`, so all artifact paths must continue to point at real current-task documents.

```yaml
task_id: <task-id>
task_name: <task-name>
mode: <full|fast-track>
stage: <INTAKE|PLAN|DEV|REVIEW|TEST|HANDOFF>
review_scope: <implementation|none>
entry_tool: <tool>
tool_profile_id: <profile-id>
tool_profile_source: <user-confirmed|restored|manual>
runner_tool: <tool>
runner: <skill/script/command>
fallback_policy: <policy>
recovery_source: <current-flow|artifact-scan|manual-bootstrap>

approved_inputs:
  requirement_review: <present|missing>
  ui_review: <present|missing|not-applicable>
  technical_review: <present|absent|unknown>

delta_spec:
  required: <true|false>
  reason: <text|none>
  status: <missing|draft|confirmed|not-needed>
  path: <workspace-relative spec.md path|none>

artifact_root: <workspace-relative docs/<task-id>>
current_doc: <current artifact path>
plan_path: <workspace-relative or absolute path to plan.md>
implementation_notes_path: <workspace-relative or absolute path to implementation-notes.md|none>
review_path: <workspace-relative or absolute path to review.md|none>
test_path: <workspace-relative or absolute path to test.md|none>
handoff_path: <workspace-relative or absolute path to handoff.md|none>

tool_bindings:
  INTAKE: <tool + invocation>
  PLAN: <tool + invocation>
  DEV: <tool + invocation>
  REVIEW(implementation): <tool + invocation>
  TEST: <tool + invocation>
  HANDOFF: <tool + invocation>

gate:
  status: <passed|not passed|blocked>
  basis: <why>

next: <next action>
runtime_health_command: ..\..\scripts\memory-health.ps1 -VaultRoot {VAULT_PATH} -OrchestratorFlowPath <absolute-path>
```

## handoff.md

```markdown
# Handoff

> task_id: <task-id>
> task_name: <task-name>
> stage: <INTAKE|PLAN|DEV|REVIEW(implementation)|TEST|HANDOFF>
> next_stage: <PLAN|DEV|REVIEW(implementation)|TEST|HANDOFF|none>
> handoff_reason: <advance|loopback|fallback|resume|terminal>

## Consumed Inputs

- requirement review: <present|missing>
- ui review: <present|missing|not-applicable>
- technical review: <present|absent|unknown>
- delta-spec: <not-needed|draft|confirmed>

## Gate Basis

- current gate status: <passed|not passed|blocked>
- why: <text>

## Current Status

- latest_change_summary: <text|none>
- review_verdict: <not-run|pass|revise>
- test_conclusion: <not-run|pass|fail|blocked>
- next_focus: <text|none>

## Artifacts

- plan: <path>
- implementation-notes: <path|none>
- review: <path|none>
- test: <path|none>
- handoff: <path|none>

## Risks / Watchouts

- <risk item>

## Downstream Notes

- <delivery note>
```

## stage-history.md

```markdown
# Stage History

- 2026-04-01T10:00:00+08:00 | INTAKE -> PLAN | gate=passed | reason=approved inputs sufficient
- 2026-04-01T11:30:00+08:00 | TEST -> HANDOFF | gate=passed | reason=test.md verdict = pass
```
