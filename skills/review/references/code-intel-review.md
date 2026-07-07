# Code Intel Review

- Provider hints must be grounded to current files, commands, diffs, or logs.
- `no callers`, `no impact`, and `index says safe` are not sufficient review evidence.
- Stale indexes require real file reads and `rg` fallback.
- Providers must not decide `verdict: pass` or `verdict: revise` alone.
