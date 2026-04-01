# Tool Profile Template

Use this template when the user needs to specify an entry tool, stage bindings, or fallback policy for the development harness.

## Minimum Requirements

- `entry_tool`
- `tool_profile_id`
- Current stage binding
- `fallback_policy`
- Any future stage binding that is already known

## Template

```yaml
# Tool Profile
tool_profile_id: <profile-id>
entry_tool: <Claude | Codex | Gemini | ...>
fallback_policy: <stop_on_missing_binding | ask_user | explicit_chain>

tool_bindings:
  INTAKE: <tool + invocation>
  PLAN: <tool + invocation>
  DEV: <tool + invocation>
  REVIEW(implementation): <tool + invocation>
  TEST: <tool + invocation>
  HANDOFF: <tool + invocation or orchestrator fallback>
```

## Rules

- At minimum, the current stage must have a binding
- Orchestrator must not invent missing bindings
- `HANDOFF` can be produced by the same tool as TEST or by a dedicated documentation runner, but it must be explicit
- If `DELTA_SPEC` is expected, note which tool handles optional `spec.md`

## Example

```yaml
# Tool Profile
tool_profile_id: dev-harness-default
entry_tool: Claude
fallback_policy: ask_user

tool_bindings:
  INTAKE: Claude /orchestrator
  PLAN: Claude /plan
  DEV: Claude /implement
  REVIEW(implementation): Claude /review
  TEST: Claude /test
  HANDOFF: Claude /orchestrator
```
