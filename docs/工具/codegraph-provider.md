# CodeGraph Provider

Status: recommended optional provider.

## Use When

- impact paths are unclear
- call/dependency hints can reduce file-reading churn
- a bug fix needs caller/root-cause tracing

## Boundary

- Optional and advisory-only.
- Must not decide stage, review verdict, or TEST conclusion.
- Must not write frontmatter or `.assistant/运行时/*`.
- Stale or unavailable output uses fallback to current files and `rg`/Read.
- `no callers`, `no impact`, and `index says safe` are not final safety conclusions.

## Telemetry

Users should understand and configure telemetry before enabling any provider. Harness install/update does not enable CodeGraph or run `codegraph install`.

## Git Ignore

Local `.codegraph/` state is ignored by this repo.
