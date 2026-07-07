# CodeGraph Provider

Status: recommended optional provider.

## Use When

- impact paths are unclear
- call/dependency hints can reduce file-reading churn
- a bug fix needs caller/root-cause tracing

## Boundary

- Optional and advisory-only.
- Harness install/update does not run CodeGraph commands.
- User opt-in only.
- Must not decide stage, review verdict, or TEST conclusion.
- Must not write frontmatter or `.assistant/运行时/*`.
- Stale or unavailable output uses fallback to current files and `rg`/Read.
- `no callers`, `no impact`, and `index says safe` are not final safety conclusions.

## Manual Opt-in

These commands are examples for a user-managed environment only; harness install/update must not run them:

```powershell
codegraph telemetry off
codegraph init
codegraph status
```

If a user runs `codegraph install`, it configures that user's agent/MCP environment. It is never part of harness install/update, validation, uninstall, or stage advancement.

Windows and WSL should not share the same provider index. Create and use the index in the same OS/runtime that will query it.

## Telemetry

Users should understand and configure telemetry before enabling any provider. Harness install/update does not enable CodeGraph or run `codegraph install`.

## Git Ignore

Local `.codegraph/` state is ignored by this repo.
