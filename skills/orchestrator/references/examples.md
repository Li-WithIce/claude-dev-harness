# Examples

These are minimal but realistic examples for recovery, binding, and handoff behavior in the development harness.

## 1. current-flow.md Right After New Task Bootstrap

```yaml
task_id: auth-login-v2
task_name: 登录鉴权重构
mode: full
stage: INTAKE
entry_tool: Claude
tool_profile_id: dev-harness-default
runner_tool: Claude
runner: /orchestrator
tool_bindings:
  INTAKE: Claude /orchestrator
  PLAN: Claude /plan
  DEV: Claude /implement
  REVIEW(implementation): Claude /review
  TEST: Claude /test
  HANDOFF: Claude /orchestrator
approved_inputs:
  requirement_review: present
  ui_review: present
  technical_review: absent
artifact_root: docs/auth-login-v2
current_doc: docs/auth-login-v2/plan.md
next: Use the PLAN binding to produce docs/auth-login-v2/plan.md. Create docs/auth-login-v2/spec.md only if approved inputs prove insufficient.
runtime_health_command: ..\..\scripts\memory-health.ps1 -VaultRoot {VAULT_PATH} -OrchestratorFlowPath C:\workspace\.assistant\orchestration\current-flow.md
```

## 2. current-flow.md Fragment When INTAKE Triggers DELTA_SPEC

```yaml
stage: INTAKE
current_doc: docs/auth-login-v2/spec.md
approved_inputs:
  requirement_review: present
  ui_review: present
  technical_review: absent
delta_spec_required: true
delta_spec_reason: 缺少接口边界、降级策略与回归范围定义，当前输入不足以直接形成开发计划
next: Use the optional spec binding to produce docs/auth-login-v2/spec.md as a delta-spec, then return to PLAN.
```

## 3. handoff.md When REVIEW(implementation) Advances into TEST

```markdown
# Handoff

> task_id: auth-login-v2
> task_name: 登录鉴权重构
> stage: REVIEW(implementation)
> next_stage: TEST
> handoff_reason: advance

## Consumed Inputs

- requirement review: present
- ui review: present
- technical review: absent
- delta-spec: not needed

## Gate Basis

- current gate status: passed
- why: `review.md` has `review_verdict: pass`; only one P2 watchout remains for TEST carry-over

## Current Status

- latest_change_summary: 登录鉴权重构代码已完成，review 未发现阻塞问题
- review_verdict: pass
- test_conclusion: not-run
- next_focus: 在 TEST 阶段补做登录失败文案人工验证

## Artifacts

- plan: docs/auth-login-v2/plan.md
- implementation-notes: docs/auth-login-v2/implementation-notes.md
- review: docs/auth-login-v2/review.md
- test: none
- handoff: docs/auth-login-v2/handoff.md

## Risks / Watchouts

- [P2] 登录失败文案回归需在 TEST 中补做人工验证

## Downstream Notes

- 下一步由 TEST binding 消费当前 handoff 快照继续验证
```

## 4. handoff.md When TEST Passes and Work Enters HANDOFF

```markdown
# Handoff

> task_id: auth-login-v2
> task_name: 登录鉴权重构
> stage: HANDOFF
> next_stage: none
> handoff_reason: terminal

## Consumed Inputs

- requirement review: present
- ui review: present
- technical review: absent
- delta-spec: not needed

## Gate Basis

- current gate status: passed
- why: `test.md` verdict = `pass`

## Current Status

- latest_change_summary: 登录鉴权重构已通过 review 与 test，当前进入最终交付
- review_verdict: pass
- test_conclusion: pass
- next_focus: none

## Artifacts

- plan: docs/auth-login-v2/plan.md
- implementation-notes: docs/auth-login-v2/implementation-notes.md
- review: docs/auth-login-v2/review.md
- test: docs/auth-login-v2/test.md
- handoff: docs/auth-login-v2/handoff.md

## Risks / Watchouts

- [P2] 首次冷启动性能回归仍建议下游做线上观察

## Downstream Notes

- 验收重点：登录失败文案、token 续签、会话恢复
- 不再将本阶段终态写为 DONE
```
