# Provider Usage Recording

Provider use is recorded only when it changes risk, scope, or verification.

## Allowed Shape

```yaml
provider_context:
  provider: codegraph
  purpose: impact scan
  grounded_to:
    - skills/review/SKILL.md
  fallback: rg used because index was stale
```

## Rules

- Do not write frontmatter.
- Do not write `.assistant/运行时/*`.
- Do not write provider verdict as TEST pass/fail.
- Default audits are advisory-only.
