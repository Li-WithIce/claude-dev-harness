# Model Invocation

Orchestrator does not hardcode tools. It consumes a user-specified tool profile that binds each harness stage to a tool and invocation path.

## Binding Rules

- Stage machine fixed；tool bindings dynamic
- Bootstrap 或 recovery 后，必须记录：`entry_tool`、`tool_profile_id`、`tool_profile_source`、当前 stage binding、`fallback_policy`
- 用户可以提供完整 profile，也可以只提供当前 stage 和有限 fallback。未来 stage binding 缺失时，不得默认补全，必须停下询问
- repo 可提供命名 preset profiles；只有当用户显式选择、恢复状态命中、或当前环境只匹配唯一 preset 时，才允许使用
- `DELTA_SPEC` 是可选制品；若它会出现，必须记录由哪个 tool 负责产出 / 修订 `spec.md`

## Tool Profile Record

在 `current-flow.md` 中至少写成这样：

```yaml
entry_tool: Claude
tool_profile_id: claude-codex-gemini-default
tool_profile_source: repo-preset
stage: PLAN
runner_tool: Claude
runner: /plan
tool_bindings:
  INTAKE: Claude /orchestrator
  PLAN: Claude /plan
  DEV: Claude /implement
  REVIEW(implementation): Claude /review
  TEST: Gemini /gemini-designer-main
  HANDOFF: Claude /orchestrator
fallback_bindings:
  DEV:
    - Codex task runner
  TEST:
    - Claude /test
    - Codex local test runner
fallback_policy: explicit_chain
```

## Repo-Shipped Presets

See `references/default-tool-profiles.md`.

Recommended preset IDs:

- `claude-codex-gemini-default`
- `codex-only`
- `codex-gemini`

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
- `PLAN / REVIEW / HANDOFF => Codex task runner with task-scoped artifact write access`
- `TEST => Codex local test runner`
- 文档类 binding 必须显式声明是否允许写入
- 如果 Codex 只作为收尾镜像同步工具出现，也必须写清是 `HANDOFF` 后的同步动作，而不是中途 stage runner

### Gemini Binding

- `TEST => Gemini validation runner`
- `HANDOFF => Claude /orchestrator`（常见组合）
- Gemini 更适合作为 TEST specialist，而不是主流程 governor

## Missing Binding Rule

如果当前 stage 或下一步 advance 所需 stage 没有 binding：

1. 停止自动推进
2. 不默认沿用其他 stage 的 tool
3. 写 `decision-needed.md` 或直接向用户请求新的 binding
