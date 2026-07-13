# State Templates

## plan.md frontmatter

```yaml
---
task_id: <task-id>
stage: PLAN | PLAN_REVIEW | IMPLEMENT | CODE_REVIEW | TEST | DONE
tool: claudecode | codex | none
tool_profile: <optional profile name>
model: <optional full model id>
updated: YYYY-MM-DD
---
```

## Workflow Descriptor

```yaml
name: harness-lite
version: 1
stages:
  PLAN:
    role: plan-author
    default_profile: harness-default-codex
    skills_whitelist: [plan, entry-router]
  PLAN_REVIEW:
    role: plan-reviewer
    default_profile: harness-default-codex
    skills_whitelist: [review]
  IMPLEMENT:
    role: implementer
    default_profile: harness-default-codex
    skills_whitelist: [implement]
  CODE_REVIEW:
    role: code-reviewer
    default_profile: harness-default-codex
    skills_whitelist: [review]
  TEST:
    role: tester
    default_profile: harness-default-codex
    skills_whitelist: [test]
```

这份 descriptor 可选放在 `agent-configs/workflows/harness-lite.yaml`，只为下一 stage 提供 `workflow-default` fallback；它不改变 `plan.md` frontmatter 仍是唯一当前 stage 真相源。

## Team Preset Template

```yaml
name: harness-lite
version: 1
single_writer:
  owner: leader
  members_read_only_path_prefixes:
    - .assistant/
    - docs/tasks/{task_id}/
members:
  - role: plan-author
    backend: codex
    model: gpt-5.5/xhigh
    skills_whitelist: [plan, entry-router]
    role_prompt_ref: agent-configs/role-prompts/plan-author.md
```

## Role Prompt Template

```markdown
# Role: <role>

You are the <role> for the harness-lite workflow.

## Stage scope
<which stage(s) this role drives>

## Authority
- Read-only path prefixes:
  - .assistant/
  - docs/tasks/{task_id}/
- Write: NONE under either prefix (leader is the sole vault writer)
- Allowed skills: <skills_whitelist>

## Handoff back to leader
Use team_send_message(to='Leader', summary='<S>', message='<M>') with structured findings.
Do not call advance-stage.ps1 directly.
Do not call team_task_update to mutate task state.
```

## skill-manifest.json

路径：`docs/tasks/{task_id}/skill-manifest.json`

```json
{
  "version": 1,
  "task_id": "<task-id>",
  "stage": "PLAN_REVIEW",
  "tool": "codex",
  "available_commands": [
    {
      "name": "review",
      "description": "..."
    }
  ],
  "generated_at": "2026-04-25T10:00:00.0000000Z"
}
```

这是 Phase 3 的 per-task best-effort 产物，不是真相源；生成失败只记 stderr 诊断，不阻塞 stage 推进。

## skills-index.md

路径：`docs/tasks/{task_id}/skills-index.md`

```markdown
<!-- generated at 2026-04-25T10:00:00.0000000Z -->
# Skills available at TEST (backend hint: codex)

- **test** — ...
```

## plan.md skeleton

```markdown
# <Task Title>

## Clarification
- 验收标准: ...
- 非目标: ...
- 受影响目录: ...
- 回滚策略: ...
- ui: not-applicable

## User Confirmation
- status: draft

## Change Contract
- change_type: task | feature | enhance | refactor
- affected_paths:
  - <path>

## Plan
- TODO 1: ...

## Verification
- `pwsh -File tests/...`

## Risks
- ...

## Plan Review

## Implementation Notes

## Code Review
```

`## Change Contract` 是可选 section。未启用时整段删除（不要留占位 `<path>`）。启用时 `change_type` 必须在枚举内，`affected_paths` 至少一条非占位条目。

## append-only run block

```markdown
### Run 2 · 2026-04-09 11:00 · runner: Codex
- verdict: pass
- findings: none
- next: none
- invocation: skill=codex mode=adapter tool=codex ok=True status=delegated
```

`Plan Review` 和 `Code Review` 的每个 run 恰好一个 verdict 和一个 findings 形态；latest `pass + P0/P1`、`revise + none` 会被拒绝，`pass + 仅 P2/P3` 合法。`Implementation Notes` 记录 `changed/tests/risks/next`。Phase 3 的 invocation trace 只能 append 到既有 run 内；没有 `### Run N` 时要安全跳过。

## spec.md skeleton

```markdown
# <Task Title> Spec

## Gap
- 当前输入缺什么。

## Constraint
- 开发边界。

## Verification Delta
- 需要额外验证什么。
```

## test.md skeleton

```markdown
# Test Report

## Summary
- ...

## Scope
- ...

## Inputs Reviewed
- `docs/tasks/{task_id}/plan.md`

## Test Approach
- ...

## Findings
- ...

## Evidence
- command: `pwsh -NoProfile -File ...`
- exit_code: 0
- executed_at: 2026-07-10T10:00:00+08:00
- revision: 0123456789abcdef0123456789abcdef01234567
- evidence_path: `docs/tasks/{task_id}/test.md`（workspace 内已存在的相对路径）

## Risks / Gaps
- ...

## Conclusion
pass

## Handoff
- delivery: ...
- follow_up: none
- current_state: ...            # optional, 长任务推荐
- key_decisions:                 # optional, 每条含 decision + why
  - decision: ...
    why: ...
- next_actions:                  # optional, 恢复后第一组动作
  - ...
```

`current_state`、`key_decisions`、`next_actions` 是 opt-in 密度扩展字段；`delivery`、`follow_up` 和 Evidence 的五个字段是最低必填。Evidence 字段各出现一次；`pass` 要求 `exit_code: 0`、含时区 ISO-8601 `executed_at`、7-40 位十六进制 git revision 或 `dirty:<64hex>`，以及 workspace 内已存在文件的相对 `evidence_path`。
