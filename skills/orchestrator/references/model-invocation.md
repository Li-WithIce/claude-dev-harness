# Model Invocation

Orchestrator does not hardcode tools. It consumes a user-specified tool profile that binds each harness stage to a tool and invocation path.

## Binding Rules

- Stage machine fixed；tool bindings dynamic
- Bootstrap 或 recovery 后，必须记录：`entry_tool`、`tool_profile_id`、当前 stage binding、`fallback_policy`
- 用户可以提供完整 profile，也可以只提供当前 stage 和有限 fallback。未来 stage binding 缺失时，不得默认补全，必须停下询问
- `DELTA_SPEC` 是可选制品；若它会出现，必须记录由哪个 tool 负责产出 / 修订 `spec.md`

## Tool Profile Record

在 `current-flow.md` 中至少写成这样：

```yaml
entry_tool: Claude
tool_profile_id: dev-harness-default
tool_profile_source: user-confirmed
stage: PLAN
runner_tool: Claude
runner: /plan
tool_bindings:
  INTAKE: Claude /orchestrator
  PLAN: Claude /plan
  DEV: Claude /implement
  REVIEW(implementation): Claude /review
  TEST: Claude /test
  HANDOFF: Claude /orchestrator
fallback_policy: ask_user
```

## Example Binding Snippets

### Claude Skill Bindings

- `INTAKE => Claude /orchestrator`
- `PLAN => Claude /plan`
- `DEV => Claude /implement`
- `REVIEW(implementation) => Claude /review`
- `TEST => Claude /test`
- `HANDOFF => Claude /orchestrator`

### Codex Binding

- `DEV => Codex task runner`
- `TEST => Codex local test runner`
- 文档类 binding 必须显式声明是否允许写入
- 如果 Codex 只作为收尾镜像同步工具出现，也必须写清是 `HANDOFF` 后的同步动作，而不是中途 stage runner

### Gemini Binding

- `TEST => Gemini validation runner`
- `HANDOFF => Claude /orchestrator`（常见组合）

## Missing Binding Rule

如果当前 stage 或下一步 advance 所需 stage 没有 binding：

1. 停止自动推进
2. 不默认沿用其他 stage 的 tool
3. 写 `decision-needed.md` 或直接向用户请求新的 binding
