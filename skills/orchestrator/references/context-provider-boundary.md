# Context Provider Boundary Reference

- Providers are advisory-only.
- Provider output is evidence candidate, not workflow truth.
- Providers must not write v2 task state, Evidence, Approval, review verdicts or shared pointers. Retained v1 artifacts are history only.
- Provider absence or stale/conflicting output falls back to current repo files and `rg`/Read.
- Install/update/validation scripts must not auto-install, connect, register, or configure providers.
