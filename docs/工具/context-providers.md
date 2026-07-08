# Context Providers

Dev Harness works without external providers.

## Built-In Authority

- `docs/tasks/{task_id}/`
- current repo files
- `.assistant`
- command output and diffs

## Optional Providers

- CodeGraph: optional code-intel provider
- agentmemory: optional historical recall sidecar
- codedb-mcp: experimental heavyweight code DB

## Rules

- Providers are advisory-only.
- Provider output must be grounded to current repo evidence.
- Provider absence, stale indexes, or conflicts fall back to `rg`/Read/manual inspection.
- Install/update scripts do not auto-install, connect, register, or configure providers.
