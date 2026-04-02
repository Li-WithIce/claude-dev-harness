# Tool Profile Template

Use this template when the user needs to specify an entry tool, stage bindings, or fallback policy for the development harness.

Prefer a repo preset from `references/default-tool-profiles.md` before creating a one-off custom profile.

## Minimum Requirements

- `entry_tool`
- `tool_profile_id`
- `tool_profile_source`
- Current stage binding
- `fallback_policy`
- Any future stage binding that is already known

## Template

```yaml
# Tool Profile
tool_profile_id: <profile-id>
tool_profile_source: <repo-preset | user-confirmed | restored | manual>
entry_tool: <Claude | Codex | Gemini | ...>
fallback_policy: <stop_on_missing_binding | ask_user | explicit_chain>

tool_bindings:
  INTAKE: <tool + invocation>
  PLAN: <tool + invocation>
  DEV: <tool + invocation>
  REVIEW(implementation): <tool + invocation>
  TEST: <tool + invocation>
  HANDOFF: <tool + invocation or orchestrator fallback>

fallback_bindings:
  <STAGE>:
    - <fallback tool + invocation>
    - <fallback tool + invocation>
```

## Rules

- At minimum, the current stage must have a binding
- Orchestrator must not invent missing bindings
- If `fallback_policy = explicit_chain`, write the actual chain under `fallback_bindings`
- `HANDOFF` can be produced by the same tool as TEST or by a dedicated documentation runner, but it must be explicit
- If `DELTA_SPEC` is expected, note which tool handles optional `spec.md`

## Example

```yaml
# Tool Profile
tool_profile_id: codex-gemini
tool_profile_source: repo-preset
entry_tool: Codex
fallback_policy: explicit_chain

tool_bindings:
  INTAKE: Codex task runner (orchestrator bootstrap)
  PLAN: Codex task runner (plan artifact)
  DEV: Codex task runner (implementation)
  REVIEW(implementation): Codex task runner (implementation review)
  TEST: Gemini /gemini-designer-main
  HANDOFF: Codex task runner (handoff)

fallback_bindings:
  TEST:
    - Codex local test runner
```
