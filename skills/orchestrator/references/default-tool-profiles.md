# Default Tool Profiles

These are repo-shipped preset tool profiles for the development harness.

They are not hidden defaults. A preset becomes active only when one of the following is true:

- `current-flow.md` already records that `tool_profile_id`
- the user explicitly selects that preset
- the user states the available tool combination, and it maps to exactly one repo preset; in that case record `tool_profile_source: repo-preset`

If more than one preset could fit, or any required stage binding is still unclear, stop and write `decision-needed.md`.

## Preset Selection Rules

1. Prefer the restored `tool_profile_id` from `current-flow.md`
2. If the user explicitly names a preset, use it
3. If the user only names the installed tools, select the unique matching preset
4. If selection is still ambiguous, ask or stop

## Preset: `claude-codex-gemini-default`

Use when:

- Claude is available as the main workflow host
- Codex is available for optional DEV delegation
- Gemini is available for TEST-first validation

```yaml
tool_profile_id: claude-codex-gemini-default
entry_tool: Claude
tool_profile_source: repo-preset
fallback_policy: explicit_chain

tool_bindings:
  INTAKE: Claude /orchestrator
  PLAN: Claude /plan
  DEV: Claude /implement
  REVIEW(implementation): Claude /review
  TEST: Gemini /gemini-designer-main
  HANDOFF: Claude /orchestrator

fallback_bindings:
  DEV:
    - Codex task runner (only when user explicitly delegates or primary runner is blocked)
  TEST:
    - Claude /test
    - Codex local test runner
```

Notes:

- This is the recommended full-host profile
- `TEST` is Gemini-first, but evidence collection may still happen locally before Gemini reads it
- `HANDOFF` stays on Claude so shared runtime writeback remains on the entry host

## Preset: `codex-only`

Use when:

- Codex is the only practical workflow host
- Gemini is unavailable or not selected for TEST

```yaml
tool_profile_id: codex-only
entry_tool: Codex
tool_profile_source: repo-preset
fallback_policy: ask_user

tool_bindings:
  INTAKE: Codex task runner (orchestrator bootstrap)
  PLAN: Codex task runner (plan artifact)
  DEV: Codex task runner (implementation)
  REVIEW(implementation): Codex task runner (implementation review)
  TEST: Codex local test runner
  HANDOFF: Codex task runner (handoff)
```

Notes:

- This is the recommended profile when the machine has no practical Claude host
- It avoids Gemini-specific TEST dependencies
- If later the user enables Gemini for TEST, switch to `codex-gemini`

## Preset: `codex-gemini`

Use when:

- Codex should drive the main workflow
- Gemini is available specifically for TEST

```yaml
tool_profile_id: codex-gemini
entry_tool: Codex
tool_profile_source: repo-preset
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

Notes:

- This is the recommended no-Claude application profile
- Codex remains the main host for state progression and handoff
- Gemini is treated as a TEST specialist, not a parallel governor
