# Context Provider Boundary Reference

- Providers are advisory-only.
- Provider output is evidence candidate, not workflow truth.
- Providers must not write frontmatter, TEST conclusion, review verdict, or `.assistant/运行时/*`.
- Provider absence or stale/conflicting output falls back to current repo files and `rg`/Read.
- Install/update/validation scripts must not auto-install, connect, register, or configure providers.
