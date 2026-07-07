# Provider Usage Recording

Provider use is recorded only when it changes risk, scope, or verification.

## Allowed Shape

```yaml
provider_context:
  - provider: codegraph | agentmemory | codedb-mcp | none
    purpose: impact-scan | historical-recall | risk-scan | test-scope
    grounded_to:
      - path/or/command
    fallback: rg/read/manual-inspection
    limitations: stale-index | historical-only | unavailable | none
```

## Rules

- Do not write frontmatter.
- Do not affect stage advancement.
- Do not write `.assistant/运行时/*`.
- Do not decide review verdict.
- Do not write provider verdict as TEST pass/fail.
- Default audits are advisory-only.
- If no provider was used, write `provider_context: none` or omit the block.
